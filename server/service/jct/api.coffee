import moment from 'moment'
import mailgun from 'mailgun-js'
import fs from 'fs'
import path from 'path'
import tar from 'tar'
import Future from 'fibers/future'
import { Random } from 'meteor/random'
import unidecode from 'unidecode'
import csvtojson from 'csvtojson'
import jsYaml from 'js-yaml'
import { Match } from 'meteor/check'
import stream from 'stream'

'''
The JCT API was a plugin for the noddy API stack, however it has since been 
separated out to a standalone app. It has the smallest amount of noddy code that 
it required, to keep it simple for future maintenance as a separate project. 
It is possible that the old noddy codebase may have useful parts for future 
development though, so consider having a look at it when new requirements come up.

This API defines the routes needed to support the JCT UIs, and the admin feed-ins 
from sheets, and collates source data from DOAJ and OAB systems, as well as other 
services run within the leviathan noddy API stack (such as the academic search 
capabilities it already had).

jct project API spec doc:
https://github.com/antleaf/jct-project/blob/master/api/spec.md

algorithm spec docs:
https://docs.google.com/document/d/1-jdDMg7uxJAJd0r1P7MbavjDi1r261clTXAv_CFMwVE/edit?ts=5efb583f
https://docs.google.com/spreadsheets/d/11tR_vXJ7AnS_3m1_OSR3Guuyw7jgwPgh3ETgsIX0ltU/edit#gid=105475641

# Expected result examples: https://docs.google.com/document/d/1AZX_m8EAlnqnGWUYDjKmUsaIxnUh3EOuut9kZKO3d78/edit

given a journal, funder(s), and institution(s), tell if they are compliant or not
journal meets general JCT plan S compliance by meeting certain criteria
or journal can be applying to be in DOAJ if not in there yet
or journal can be in transformative journals list (which will be provided by plan S). If it IS in the list, it IS compliant
institutions could be any, and need to be tied to transformative agreements (which could be with larger umbrella orgs)
or an institutional affiliation to a transformative agreement could make a journal suitable
funders will be a list given to us by JCT detailing their particular requirements - in future this may alter whether or not the journal is acceptable to the funder
'''

# define the necessary collections - institution is defined global so a separate script was able to initialise it
# where devislive is true, the live indexes are actually reading from the dev ones. This is handy for 
# datasets that are the same, such as institutions, journals, and transformative agreements
# but compliance and unknown should be unique as they could have different results on dev or live depending on code changes
# to do alterations to code on dev that may change how institutions, journals, or agreements are constructed, comment out the devislive setting
# NOTE: doing this would mean live would not have recent data to read from, so after this code change is deployed to live 
# it should be followed by manually triggering a full import on live
# (for convenience the settings have initially been set up to only run import on dev as well, to make the most 
# of the dev machine and minimise any potential memory or CPU intense work on the live machine - see the settings.json file for this config)

index_name = API.settings.es.index ? 'jct'
@jct_institution = new API.collection {index:index_name, type:"institution", devislive: true}
jct_journal = new API.collection {index:index_name, type:"journal"}
jct_agreement = new API.collection {index:index_name, type:"agreement"}
jct_compliance = new API.collection {index:index_name, type:"compliance"}
jct_unknown = new API.collection {index:index_name, type:"unknown"}
jct_funder_config = new API.collection {index:index_name, type:"funder_config"}
jct_funder_language = new API.collection {index:index_name, type:"funder_language"}

# define endpoints that the JCT requires (to be served at a dedicated domain)
API.add 'service/jct', get: () -> return 'cOAlition S Journal Checker Tool. Service provided by Cottage Labs LLP. Contact us@cottagelabs.com'

API.add 'service/jct/calculate', get: () -> return API.service.jct.calculate this.queryParams

API.add 'service/jct/suggest/:which', get: () -> return API.service.jct.suggest[this.urlParams.which] undefined, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which/:ac', get: () -> return API.service.jct.suggest[this.urlParams.which] this.urlParams.ac, this.queryParams.from, this.queryParams.size

API.add 'service/jct/ta', 
  get: () -> 
    if this.queryParams.issn or this.queryParams.journal
      res = API.service.jct.ta this.queryParams.issn ? this.queryParams.journal, this.queryParams.institution ? this.queryParams.ror
      ret = []
      for r in (if not _.isArray(res) then [res] else res)
        if r.compliant is 'yes'
          ret.push issn: r.issn, ror: r.ror, result: res
      return if ret.length then ret else 404
    else
      return jct_agreement.search this.queryParams
API.add 'service/jct/ta/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.ta.import this.queryParams.mail), 1
    return true

API.add 'service/jct/sa_prohibited',
  get: () ->
    return API.service.jct.sa_prohibited this.queryParams.issn
API.add 'service/jct/sa_prohibited/import',
  get: () ->
    Meteor.setTimeout (() => API.service.jct.sa_prohibited undefined, true), 1
    return true

API.add 'service/jct/retention', 
  get: () -> 
    return API.service.jct.retention this.queryParams.issn
API.add 'service/jct/retention/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.retention undefined, true), 1
    return true

API.add 'service/jct/tj', get: () -> return jct_journal.search this.queryParams, {restrict: [{exists: {field: 'tj'}}]}
API.add 'service/jct/tj/:issn', 
  get: () -> 
    res = API.service.jct.tj this.urlParams.issn
    return if res?.compliant isnt 'yes' then 404 else issn: this.urlParams.issn, transformative_journal: true
API.add 'service/jct/tj/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.tj undefined, true), 1
    return true

API.add 'service/jct/funder', get: () -> return API.service.jct.funders undefined, this.queryParams.refresh
API.add 'service/jct/funder/:iid', get: () -> return API.service.jct.funders this.urlParams.iid

API.add 'service/jct/feedback',
  get: () -> return API.service.jct.feedback this.queryParams
  post: () -> return API.service.jct.feedback this.bodyParams

API.add 'service/jct/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.import this.queryParams.refresh), 1
    return true

API.add 'service/jct/unknown', get: () -> return jct_unknown.search this.queryParams
API.add 'service/jct/unknown/:start/:end', 
  get: () -> 
    csv = false
    if typeof this.urlParams.start is 'string' and this.urlParams.start.indexOf('.csv') isnt -1
      this.urlParams.start = this.urlParams.start.replace('.csv','')
      csv = true
    else if typeof this.urlParams.end is 'string' and this.urlParams.end.indexOf('.csv') isnt -1
      this.urlParams.end = this.urlParams.end.replace('.csv','')
      csv = true
    res = []
    if typeof this.urlParams.start in ['number','string'] or typeof this.urlParams.end in ['number','string']
      q = if typeof this.urlParams.start in ['number','string'] then 'createdAt:>=' + this.urlParams.start else ''
      if typeof this.urlParams.end in ['number','string']
        q += ' AND ' if q isnt ''
        q += 'createdAt:<' + this.urlParams.end
    else
      q = '*'
    for un in unks = jct_unknown.fetch q
      params = un._id.split '_'
      res.push route: un.route, issn: params[1], funder: params[0], ror: params[2], log: un.log
    if csv
      fn = 'JCT_export_' + this.urlParams.start + (if this.urlParams.end then '_' + this.urlParams.end else '') + ".csv"
      this.response.writeHead(200, {'Content-disposition': "attachment; filename=" + fn, 'Content-type': 'text/csv; charset=UTF-8', 'Content-Encoding': 'UTF-8'})
      this.response.end API.service.jct.csv res
    else
      return res

API.add 'service/jct/journal', get: () -> return jct_journal.search this.queryParams
API.add 'service/jct/institution', get: () -> return jct_institution.search this.queryParams
API.add 'service/jct/compliance', get: () -> return jct_compliance.search this.queryParams
# the results that have already been calculated. These used to get used to re-serve as a 
# faster cached result, but uncertainties over agreement on how long to cache stuff made 
# this unnecessarily complex, so these are only stored as a history now.

API.add 'service/jct/test', get: () -> return API.service.jct.test this.queryParams

API.add 'service/jct/funder_config', get: () ->
  return API.service.jct.funder_config undefined, this.queryParams.refresh
API.add 'service/jct/funder_config/:iid', get: () -> return API.service.jct.funder_config this.urlParams.iid
API.add 'service/jct/funder_config/import', get: () ->
  Meteor.setTimeout (() => API.service.jct.funder_config undefined, true), 1
  return true

API.add 'service/jct/funder_language', get: () ->
  return API.service.jct.funder_language undefined, this.queryParams.refresh
API.add 'service/jct/funder_language/:iid', get: () -> return API.service.jct.funder_language this.urlParams.iid
API.add 'service/jct/funder_language/import', get: () ->
  Meteor.setTimeout (() => API.service.jct.funder_language undefined, true), 1
  return true

_jct_clean = (str) ->
  pure = /[!-/:-@[-`{-~¡-©«-¬®-±´¶-¸»¿×÷˂-˅˒-˟˥-˫˭˯-˿͵;΄-΅·϶҂՚-՟։-֊־׀׃׆׳-״؆-؏؛؞-؟٪-٭۔۩۽-۾܀-܍߶-߹।-॥॰৲-৳৺૱୰௳-௺౿ೱ-ೲ൹෴฿๏๚-๛༁-༗༚-༟༴༶༸༺-༽྅྾-࿅࿇-࿌࿎-࿔၊-၏႞-႟჻፠-፨᎐-᎙᙭-᙮᚛-᚜᛫-᛭᜵-᜶។-៖៘-៛᠀-᠊᥀᥄-᥅᧞-᧿᨞-᨟᭚-᭪᭴-᭼᰻-᰿᱾-᱿᾽᾿-῁῍-῏῝-῟῭-`´-῾\u2000-\u206e⁺-⁾₊-₎₠-₵℀-℁℃-℆℈-℉℔№-℘℞-℣℥℧℩℮℺-℻⅀-⅄⅊-⅍⅏←-⏧␀-␦⑀-⑊⒜-ⓩ─-⚝⚠-⚼⛀-⛃✁-✄✆-✉✌-✧✩-❋❍❏-❒❖❘-❞❡-❵➔➘-➯➱-➾⟀-⟊⟌⟐-⭌⭐-⭔⳥-⳪⳹-⳼⳾-⳿⸀-\u2e7e⺀-⺙⺛-⻳⼀-⿕⿰-⿻\u3000-〿゛-゜゠・㆐-㆑㆖-㆟㇀-㇣㈀-㈞㈪-㉃㉐㉠-㉿㊊-㊰㋀-㋾㌀-㏿䷀-䷿꒐-꓆꘍-꘏꙳꙾꜀-꜖꜠-꜡꞉-꞊꠨-꠫꡴-꡷꣎-꣏꤮-꤯꥟꩜-꩟﬩﴾-﴿﷼-﷽︐-︙︰-﹒﹔-﹦﹨-﹫！-／：-＠［-｀｛-･￠-￦￨-￮￼-�]|\ud800[\udd00-\udd02\udd37-\udd3f\udd79-\udd89\udd90-\udd9b\uddd0-\uddfc\udf9f\udfd0]|\ud802[\udd1f\udd3f\ude50-\ude58]|\ud809[\udc00-\udc7e]|\ud834[\udc00-\udcf5\udd00-\udd26\udd29-\udd64\udd6a-\udd6c\udd83-\udd84\udd8c-\udda9\uddae-\udddd\ude00-\ude41\ude45\udf00-\udf56]|\ud835[\udec1\udedb\udefb\udf15\udf35\udf4f\udf6f\udf89\udfa9\udfc3]|\ud83c[\udc00-\udc2b\udc30-\udc93]/g;
  str = str.replace(pure, ' ')
  return str.toLowerCase().replace(/ +/g,' ').trim()

# and now define the methods
API.service ?= {}
API.service.jct = {}
API.service.jct.suggest = {}
API.service.jct.suggest.funder = (str, from, size) ->
  res = []
  for f in API.service.jct.funders()
    matches = true
    if str isnt f.id
      for s in (if str then str.toLowerCase().split(' ') else [])
        if s not in ['of','the','and'] and f.funder.toLowerCase().indexOf(s) is -1
          matches = false
    res.push({title: f.funder, id: f.id}) if matches
  return total: res.length, data: res

API.service.jct.suggest.institution = (str, from, size) ->
  # TODO add an import method from wikidata or ROR, and have the usual import routine check for changes on a suitable schedule
  if typeof str is 'string' and str.length is 9 and rec = jct_institution.get str
    delete rec[x] for x in ['createdAt', 'created_date', '_id', 'description', 'values', 'wid']
    return total: 1, data: [rec]
  else
    q = {query: {filtered: {query: {}, filter: {bool: {should: []}}}}, size: size}
    q.from = from if from?
    if str
      str = _jct_clean(str).replace(/the /gi,'')
      qry = (if str.indexOf(' ') is -1 then 'id:' + str + '* OR ' else '') + '(title:' + str.replace(/ /g,' AND title:') + '*) OR (alternate:' + str.replace(/ /g,' AND alternate:') + '*) OR (description:' + str.replace(/ /g,' AND description:') + '*) OR (values:' + str.replace(/ /g,' AND values:') + '*)'
      q.query.filtered.query.query_string = {query: qry}
    else
      q.query.filtered.query.match_all = {}
    res = jct_institution.search q
    unis = []
    starts = []
    extra = []
    for rec in res?.hits?.hits ? []
      delete rec._source[x] for x in ['createdAt', 'created_date', '_id', 'description', 'values', 'wid']
      if str
        if rec._source.title.toLowerCase().indexOf('universit') isnt -1
          unis.push rec._source
        else if _jct_clean(rec._source.title).replace('the ','').replace('university ','').replace('of ','').startsWith(str.replace('the ','').replace('university ','').replace('of ',''))
          starts.push rec._source
        else if str.indexOf(' ') is -1 or unidecode(str) isnt str # allow matches on more random characters that may be matching elsewhere in the data but not in the actual title
          extra.push rec._source
      else
        extra.push rec._source
    ret = total: res?.hits?.total ? 0, data: _.union unis.sort((a, b) -> return a.title.length - b.title.length), starts.sort((a, b) -> return a.title.length - b.title.length), extra.sort((a, b) -> return a.title.length - b.title.length)
  
    if ret.data.length < 10
      seen = []
      seen.push(sr.id) for sr in ret.data
      q = {query: {filtered: {query: {}, filter: {bool: {should: []}}}}, size: size}
      q.from = from if from?
      if str
        str = _jct_clean(str).replace(/the /gi,'')
        q.query.filtered.query.query_string = {query: (if str.indexOf(' ') is -1 then 'ror.exact:"' + str + '" OR ' else '') + '(institution:' + str.replace(/ /g,' AND institution:') + '*)'}
      else
        q.query.filtered.query.query_string = {query: 'ror:*'}
      res = jct_agreement.search q
      if res?.hits?.total
        ret.total += res.hits.total
        unis = []
        starts = []
        extra = []
        for rec in res?.hits?.hits ? []
          if rec._source.ror not in seen
            rc = {title: rec._source.institution, id: rec._source.ror, ta: true}
            if str
              if rc.title.toLowerCase().indexOf('universit') isnt -1
                unis.push rc
              else if _jct_clean(rc.title).replace('the ','').replace('university ','').replace('of ','').startsWith(str.replace('the ','').replace('university ','').replace('of ',''))
                starts.push rc
              else if rec._source.ror.indexOf(str) is 0 and unidecode(str) isnt str # allow matches on more random characters that may be matching elsewhere in the data but not in the actual title
                extra.push rc
            else
              extra.push rc
        ret.data = _.union ret.data, _.union unis.sort((a, b) -> return a.title.length - b.title.length), starts.sort((a, b) -> return a.title.length - b.title.length), extra.sort((a, b) -> return a.title.length - b.title.length)
    return ret

API.service.jct.suggest.journal = (str, from, size) ->
  q = {query: {filtered: {query: {query_string: {query: 'issn:* AND NOT discontinued:true AND NOT dois:0'}}, filter: {bool: {should: []}}}}, size: size, _source: {includes: ['title','issn','publisher','src']}}
  q.from = from if from?
  if str and str.replace(/\-/g,'').length
    if str.indexOf(' ') is -1
      if str.indexOf('-') isnt -1 and str.length is 9
        q.query.filtered.query.query_string.query = 'issn.exact:"' + str + '" AND NOT discontinued:true AND NOT dois:0'
      else
        q.query.filtered.query.query_string.query = 'NOT discontinued:true AND NOT dois:0 AND ('
        if str.indexOf('-') isnt -1
          q.query.filtered.query.query_string.query += '(issn:"' + str.replace('-','" AND issn:') + '*)'
        else
          q.query.filtered.query.query_string.query += 'issn:' + str + '*'
        q.query.filtered.query.query_string.query += ' OR title:"' + str + '" OR title:' + str + '* OR title:' + str + '~)'
    else
      str = _jct_clean str
      q.query.filtered.query.query_string.query = 'issn:* AND NOT discontinued:true AND NOT dois:0 AND (title:"' + str + '" OR '
      q.query.filtered.query.query_string.query += (if str.indexOf(' ') is -1 then 'title:' + str + '*' else '(title:' + str.replace(/ /g,'~ AND title:') + '*)') + ')'
  res = jct_journal.search q
  starts = []
  extra = []
  for rec in res?.hits?.hits ? []
    if not str or JSON.stringify(rec._source.issn).indexOf(str) isnt -1 or _jct_clean(rec._source.title).startsWith(str)
      starts.push rec._source
    else
      extra.push rec._source
    rec._source.id = rec._source.issn[0]
  return total: res?.hits?.total ? 0, data: _.union starts.sort((a, b) -> return a.title.length - b.title.length), extra.sort((a, b) -> return a.title.length - b.title.length)


API.service.jct.calculate = (params={}, refresh) ->
  # given funder(s), journal(s), institution(s), find out if compliant or not
  # note could be given lists of each - if so, calculate all and return a list

  # Get parameters
  if params.issn
    params.journal = params.issn
    delete params.issn
  if params.ror
    params.institution = params.ror
    delete params.ror
  refresh ?= params.refresh if params.refresh?
  # all possible checks we can perform
  checks = {
    'self_archiving': 'sa',
    'fully_oa': 'fully_oa',
    'ta' : 'ta',
    'tj': 'tj',
    'hybrid': 'hybrid'
  }
  check_retention = true
  check_sa_prohibition = true

  # initialise basic result object
  res =
    request:
      started: Date.now()
      ended: undefined
      took: undefined
      journal: []
      funder: []
      institution: []
      checks: checks
    compliant: false
    cache: true
    results: []
    cards: undefined

  return res if not params.journal

  # Get the matching data for the request parameters from suggest
  issnsets = {} # set of all matching ISSNs for given journal (ISSN)
  for p in ['funder','journal','institution']
    params[p] = params[p].toString() if typeof params[p] is 'number'
    params[p] = params[p].split(',') if typeof params[p] is 'string'
    params[p] ?= []
    for v in params[p]
      if sg = API.service.jct.suggest[p] v
        if sg.data and sg.data.length
          ad = sg.data[0]
          res.request[p].push {id: ad.id, title: ad.title, issn: ad.issn, publisher: ad.publisher}
          issnsets[v] ?= ad.issn if p is 'journal' and _.isArray(ad.issn) and ad.issn.length
      res.request[p].push({id: v}) if not sg?.data

  # calculate compliance for each combo, for all the routes
  rq = Random.id() # random ID to store with the cached results, to measure number of unique requests that aggregate multiple sets of entities
  checked = 0
  _check = (funder, journal, institution) ->
    hascompliant = false
    allcached = true
    _results = []

    # get data from oa.works
    oa_permissions = API.service.jct.oa_works (issnsets[journal] ? journal), (if institution? then institution else undefined)
    # get funder config
    funder_config = API.service.jct.funder_config funder, undefined

    # checks to perform for journal
    _journal_checks = (funder_config) ->
      journal_checks = []
      if funder_config.routes? and funder_config.routes
        for route in funder_config.routes
          if route in checks and route.calculate? and route.calculate is true
            journal_checks.push(route)
      return journal_checks
    res.request.checks = _journal_checks(funder_config)
    cr = {}
    for route, route_method of checks
      cr[route_method] = route in res.request.checks

    # calculate compliance for the route (which)
    _ck = (route_method) ->
      allcached = false
      Meteor.setTimeout () ->
        if route_method is 'sa'
          rs = API.service.jct.sa (issnsets[journal] ? journal), (if institution? then institution else undefined), funder, oa_permissions, check_retention, check_sa_prohibition
        else if route_method is 'hybrid'
          rs =  API.service.jct.hybrid (issnsets[journal] ? journal), (if institution? then institution else undefined), funder, oa_permissions
        else
          rs = API.service.jct[route_method] (issnsets[journal] ? journal), (if institution? and route_method is 'ta' then institution else undefined)
        if rs
          for r in (if _.isArray(rs) then rs else [rs])
            hascompliant = true if r.compliant is 'yes'
            if r.compliant is 'unknown'
              API.service.jct.unknown r, funder, journal, institution
            _results.push r
        cr[route_method] = Date.now()
      , 1
    # calculate compliance for each route in checks
    for r, c of checks
      _ck(c) if cr[c]

    # wait for all checks to finish
    # If true, the check is not yet done. Once done, a check will have the current datetime
    while cr.sa is true or cr.fully_oa is true or cr.ta is true or cr.tj is true or cr.hybrid is true
      future = new Future()
      Meteor.setTimeout (() -> future.return()), 100
      future.wait()

    # calculate cards
    cards_result = _cards_for_display(funder_config, _results)
    res.cards = cards_result[0]
    res.compliant = true if cards_result[1]

    delete res.cache if not allcached
    # store a new set of results every time without removing old ones, to keep track of incoming request amounts
    jct_compliance.insert journal: journal, funder: funder, institution: institution, check_retention: check_retention, rq: rq, checks: checks, compliant: hascompliant, cache: allcached, results: _results
    res.results.push(rs) for rs in _results

    checked += 1

  # make a list of all possible valid combos of params
  combos = []
  for j in (if params.journal and params.journal.length then params.journal else [undefined])
    cm = journal: j
    for f in (if params.funder and params.funder.length then params.funder else [undefined]) # does funder have any effect? - probably not right now, so the check will treat them the same
      cm = _.clone cm
      cm.funder = f
      for i in (if params.institution and params.institution.length then params.institution else [undefined])
        cm = _.clone cm
        cm.institution = i
        combos.push cm

#  console.log 'Calculating for:'
#  console.log combos

  # start an async check for every combo
  _prl = (combo) -> Meteor.setTimeout (() -> _check combo.funder, combo.journal, combo.institution), 1
  for c in combos
    if c.institution isnt undefined or c.funder isnt undefined or c.journal isnt undefined
      _prl c
    else
      checked += 1
  while checked isnt combos.length
    future = new Future()
    Meteor.setTimeout (() -> future.return()), 100
    future.wait()

  res.request.ended = Date.now()
  res.request.took = res.request.ended - res.request.started
  return res


# For a TA to be in force, an agreement record for the the ISSN and also one for 
# the ROR mus be found, and the current date must be after those record start dates 
# and before those record end dates. A journal and institution could be in more than 
# one TA at a time - return all cases where both journal and institution are in the 
# same TA
API.service.jct.ta = (issn, ror) ->
  issn = issn.split(',') if typeof issn is 'string'
  tas = []
  qr = ''
  if issn
    qr += 'issn.exact:"' + issn.join('" OR issn.exact:"') + '"'
  if ror
    qr += ' OR ' if qr isnt ''
    if typeof ror is 'string' and ror.indexOf(',') isnt -1
      ror = ror.split(',') 
      qr += 'ror.exact:"' + ror.join('" OR ror.exact:"') + '"'
    else
      qr += 'ror.exact:"' + ror + '"'
  res =
    route: 'ta'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    ror: ror
    log: []
  # what if start or end dates do not exist, but at least one of them does? Must they all exist?
  journals = {}
  institutions = {}
  count = 0
  jct_agreement.each qr, (rec) -> # how many could this be? If many, will it be fast enough?
    count += 1
    if rec.issn?
      journals[rec.rid] = rec
    else if rec.ror?
      institutions[rec.rid] = rec
  agreements = {}
  for j of journals
    if institutions[j]?
      allow = true # avoid possibly duplicate TAs
      agreements[j] ?= {}
      for isn in (if typeof journals[j].issn is 'string' then [journals[j].issn] else journals[j].issn)
        agreements[j][isn] ?= []
        if institutions[j].ror not in agreements[j][isn]
          agreements[j][isn].push institutions[j].ror
        else
          allow = false
      if allow
        rs = _.clone res
        rs.compliant = 'yes'
        rs.qualifications = if journals[j].corresponding_authors or institutions[j].corresponding_authors then [{corresponding_authors: {}}] else []
        rs.log.push code: 'TA.Exists'
        tas.push rs
  if tas.length is 0
    res.compliant = 'no'
    res.log.push code: 'TA.NoTA'
    tas.push res
  return if tas.length is 1 then tas[0] else tas
  # NOTE there are more log codes to use in the new API log codes spec, 
  # https://github.com/CottageLabs/jct/blob/feature/api_codes/markdown/apidocs.md#per-route-response-data
  # TA.NotAcive	- TA.Active	- TA.Unknown - TA.NonCompliant - TA.Compliant
  # but it is not known how these could be used here, as all TAs in the system appear to be active - anything with an end date in the past is not imported
  # and there is no way to identify plan S compliant / not compliant  unknown from the current algorithm spec
  

# import transformative agreements data from sheets 
# https://github.com/antleaf/jct-project/blob/master/ta/public_data.md
# only validated agreements will be exposed at the following sheet
# https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=1130349201&single=true&output=csv
# get the "Data URL" - if it's a valid URL, and the End Date is after current date, get the csv from it
API.service.jct.ta.import = (mail=true) ->
  bads = []
  records = []
  res = sheets: 0, ready: 0, processed:0, records: 0, failed: [], not_processed:0
  console.log 'Starting ta import'
  batch = []
  bissns = [] # track ones going into the batch
  for ov in API.service.jct.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=1130349201&single=true&output=csv'
    res.sheets += 1
    # Removed check for TA end date. Expired TAs are handled as a part of data management
    if typeof ov?['Data URL'] is 'string' and ov['Data URL'].trim().indexOf('http') is 0
      res.ready += 1
      src = ov['Data URL'].trim()
      console.log res
      future = new Future()
      Meteor.setTimeout (() -> future.return()), 1000 # wait 1s so don't instantly send 200 requests to google
      future.wait()
      _src = (src, ov) ->
        Meteor.setTimeout () ->
          console.log src
          try
            for rec in API.service.jct.csv2json src
              for e of rec # get rid of empty things
                delete rec[e] if not rec[e]
              ri = {}
              for ik in ['Institution Name', 'ROR ID', 'Institution First Seen', 'Institution Last Seen']
                ri[ik] = rec[ik]
                delete rec[ik]
              if not _.isEmpty(ri) and not ri['Institution Last Seen'] # if these are present then it is too late to use this agreement
                ri[k] = ov[k] for k of ov
                # pick out records relevant to institution type
                ri.rid = (if ri['ESAC ID'] then ri['ESAC ID'].trim() else '') + (if ri['ESAC ID'] and ri['Relationship'] then '_' + ri['Relationship'].trim() else '') # are these sufficient to be unique?
                ri.institution = ri['Institution Name'].trim() if ri['Institution Name']
                ri.ror = ri['ROR ID'].split('/').pop().trim() if ri['ROR ID']?
                ri.corresponding_authors = true if ri['C/A Only'].trim().toLowerCase() is 'yes'
                res.records += 1
                records.push(ri) if ri.institution and ri.ror
              if not _.isEmpty(rec) and not rec['Journal Last Seen']
                rec[k] = ov[k] for k of ov
                rec.rid = (if rec['ESAC ID'] then rec['ESAC ID'].trim() else '') + (if rec['ESAC ID'] and rec['Relationship'] then '_' + rec['Relationship'].trim() else '') # are these sufficient to be unique?
                rec.issn = []
                bad = false
                for ik in ['ISSN (Print)','ISSN (Online)']
                  for isp in (if typeof rec[ik] is 'string' then rec[ik].split(',') else [])
                    if not isp? or typeof isp isnt 'string' or isp.indexOf('-') is -1 or isp.split('-').length > 2 or isp.length < 5
                      bads.push issn: isp, esac: rec['ESAC ID'], rid: rec.rid, src: src
                      bad = true
                    else if typeof isp is 'string'
                      nisp = isp.toUpperCase().trim().replace(/ /g, '')
                      rec.issn.push(nisp) if nisp.length and nisp not in rec.issn
                rec.journal = rec['Journal Name'].trim() if rec['Journal Name']?
                rec.corresponding_authors = true if rec['C/A Only'].trim().toLowerCase() is 'yes'
                res.records += 1
                if not bad and rec.journal and rec.issn.length
                  if exists = jct_journal.find 'issn.exact:"' + rec.issn.join('" OR issn.exact:"') + '"'
                    for ei in exists.issn
                      # don't take in ISSNs from TAs because we know they've been incorrect
                      rec.issn.push(ei) if typeof ei is 'string' and ei.length and ei not in rec.issn
                  else
                    inbi = false
                    # but if no record at all, not much choice so may as well accept
                    for ri in rec.issn
                      if ri in bissns
                        inbi = true
                      else
                        bissns.push ri
                    if not inbi
                      batch.push issn: rec.issn, title: rec.journal, ta: true
                  records.push rec
          catch
            console.log src + ' FAILED'
            res.failed.push src
          res.processed += 1
        , 1
      _src src, ov
    else
      src = ''
      if ov?['Data URL']
        src = ov['Data URL']
        if typeof ov['Data URL'] is 'string'
          src = ov['Data URL'].trim()
      console.log 'sheet ' + res.sheets + ' with url ' + src + ' was not processed'
      res.not_processed += 1
  while res.sheets isnt (res.processed + res.not_processed)
    future = new Future()
    Meteor.setTimeout (() -> future.return()), 5000 # wait 5s repeatedly until all sheets are done
    future.wait()
    console.log 'TA sheets still processing, ' + (res.sheets - res.processed - res.not_processed)
  if records.length
    console.log 'Removing and reloading ' + records.length + ' agreements'
    jct_agreement.remove '*'
    jct_agreement.insert records
    res.extracted = records.length
  if batch.length
    jct_journal.insert batch
    batch = []
  if mail
    API.service.jct.mail
      subject: 'JCT TA import complete'
      text: JSON.stringify res, '', 2
  if bads.length
    API.service.jct.mail
      subject: 'JCT TA import found ' + bads.length + ' bad ISSNs'
      text: bads.length + ' bad ISSNs listed in attached file'
      attachment: bads
      filename: 'bad_issns.csv'
  return res


# import transformative journals data, which should indicate if the journal IS 
# transformative or just in the list for tracking (to be transformative means to 
# have submitted to the list with the appropriate responses)
# fields called pissn and eissn will contain ISSNs to check against
# check if an issn is in the transformative journals list (to be provided by plan S)
API.service.jct.tj = (issn, refresh) ->
  if refresh
    console.log 'Starting tj import'
    recs = API.service.jct.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vT2SPOjVU4CKhP7FHOgaf0aRsjSOt-ApwLOy44swojTDFsWlZAIZViC0gdbmxJaEWxdJSnUmNoAnoo9/pub?gid=0&single=true&output=csv'
    console.log 'Retrieved ' + recs.length + ' tj records from sheet'
    for rec in recs
      tj = {}
      try tj.title = rec['Journal Title'].trim() if rec['Journal Title']
      tj.issn ?= []
      tj.issn.push(rec['ISSN (Print)'].trim().toUpperCase()) if typeof rec['ISSN (Print)'] is 'string' and rec['ISSN (Print)'].length
      tj.issn.push(rec['e-ISSN (Online/Web)'].trim().toUpperCase()) if typeof rec['e-ISSN (Online/Web)'] is 'string' and rec['e-ISSN (Online/Web)'].length
      if tj.issn and tj.issn.length
        if exists = jct_journal.find 'issn.exact:"' + tj.issn.join('" OR issn.exact:"') + '"'
          upd = {}
          # don't trust incoming ISSNs from sheets because data provided by third parties has been seen to be wrong
          #for isn in tj.issn
          #  if isn not in exists.issn
          #    upd.issn ?= []
          #    upd.issn.push isn
          upd.tj = true if exists.tj isnt true
          if JSON.stringify(upd) isnt '{}'
            jct_journal.update exists._id, upd
        else
          tj.tj = true
          jct_journal.insert tj

  issn = issn.split(',') if typeof issn is 'string'
  if issn and issn.length
    res = 
      route: 'tj'
      compliant: 'unknown'
      qualifications: undefined
      issn: issn
      log: []

    if exists = jct_journal.find 'tj:true AND (issn.exact:"' + issn.join('" OR issn.exact:"') + '")'
      res.compliant = 'yes'
      res.log.push code: 'TJ.Exists'
    else
      res.compliant = 'no'
      res.log.push code: 'TJ.NoTJ'
    return res
    # TODO note there are two more codes in the new API log code spec, 
    # TJ.NonCompliant - TJ.Compliant
    # but there is as yet no way to determine those so they are not used here yet.
  else
    return jct_journal.count 'tj:true'


# Import and check for Self-archiving prohibited list
# https://github.com/antleaf/jct-project/issues/406
# If journal in list, sa check not compliant
API.service.jct.sa_prohibited = (issn, refresh) ->
# check the sa prohibited data source first, to check if retained is false
# If retained is false, SA check is not compliant.
# will be a list of journals by ISSN
  if refresh
    counter = 0
    for rt in API.service.jct.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vQ0EEMZTikcQZV28BiCL4huv-r0RnHiDrU08j3W1fyERNasoJYuAZek5G3oQH1TUKmf_X-yC5SiHaBM/pub?gid=0&single=true&output=csv'
      counter += 1
      console.log('sa prohibited import ' + counter) if counter % 20 is 0
      rt.journal = rt['Journal Title'].trim() if typeof rt['Journal Title'] is 'string'
      rt.issn = []
      rt.issn.push(rt['ISSN (print)'].trim().toUpperCase()) if typeof rt['ISSN (print)'] is 'string' and rt['ISSN (print)'].length
      rt.issn.push(rt['ISSN (electronic)'].trim().toUpperCase()) if typeof rt['ISSN (electronic)'] is 'string' and rt['ISSN (electronic)'].length
      rt.publisher = rt.Publisher.trim() if typeof rt.Publisher is 'string'
      if rt.issn.length
        if exists = jct_journal.find 'issn.exact:"' + rt.issn.join('" OR issn.exact:"') + '"'
          upd = {}
          upd.issn ?= []
          for isn in rt.issn
            if isn not in exists.issn
              upd.issn.push isn
          upd.sa_prohibited = true if exists.sa_prohibited isnt true
          # All of the sa prohibition data is held in journal.retention
          upd.retention = rt
          if JSON.stringify(upd) isnt '{}'
            for en in exists.issn
              upd.issn.push(en) if typeof en is 'string' and en.length and en not in upd.issn
            jct_journal.update exists._id, upd
        else
          rec = sa_prohibited: true, retention: rt, issn: rt.issn, publisher: rt.publisher, title: rt.journal
          jct_journal.insert rec
    console.log('Imported ' + counter)

  if issn
    issn = issn.split(',') if typeof issn is 'string'
    res =
      route: 'self_archiving'
      compliant: 'unknown'
      qualifications: undefined
      issn: issn
      ror: undefined
      funder: undefined
      log: []

    if exists = jct_journal.find 'sa_prohibited:true AND (issn.exact:"' + issn.join('" OR issn.exact:"') + '")'
      res.log.push code: 'SA.RRException'
      res.compliant = 'no'
    else
      res.log.push code: 'SA.RRNoException'
    return res
  else
    return jct_journal.count 'sa_prohibited:true'


# what are these qualifications relevant to? TAs?
# there is no funder qualification done now, due to retention policy change decision at ened of October 2020. May be added again later.
# rights_retention_author_advice - 
# rights_retention_funder_implementation - the journal does not have an SA policy and the funder has a rights retention policy that starts in the future. 
# There should be one record of this per funder that meets the conditions, and the following qualification specific data is requried:
# funder: <funder name>
# date: <date policy comes into force (YYYY-MM-DD)
# funder implementation ones are handled directly in the calculate stage at the moment
API.service.jct.retention = (issn, refresh) ->
  # check the rights retention data source once it exists if the record is not in OAB
  # for now this is a fallback to something that is not in OAB
  # will be a list of journals by ISSN and a number 1,2,3,4,5
  if refresh
    counter = 0
    for rt in API.service.jct.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTm6sDI16Kin3baNWaAiMUfGdMEUEGXy0LRvSDnvAQTWDN_exlYGyv4gnstGKdv3rXshjSa7AUWtAc5/pub?gid=0&single=true&output=csv'
      counter += 1
      console.log('Retention import ' + counter) if counter % 20 is 0
      rt.journal = rt['Journal Name'].trim() if typeof rt['Journal Name'] is 'string'
      rt.issn = []
      rt.issn.push(rt['ISSN (print)'].trim().toUpperCase()) if typeof rt['ISSN (print)'] is 'string' and rt['ISSN (print)'].length
      rt.issn.push(rt['ISSN (online)'].trim().toUpperCase()) if typeof rt['ISSN (online)'] is 'string' and rt['ISSN (online)'].length
      rt.position = if typeof rt.Position is 'number' then rt.Position else parseInt rt.Position.trim()
      rt.publisher = rt.Publisher.trim() if typeof rt.Publisher is 'string'
      if rt.issn.length
        if exists = jct_journal.find 'issn.exact:"' + rt.issn.join('" OR issn.exact:"') + '"'
          upd = {}
          upd.issn ?= []
          for isn in rt.issn
            if isn not in exists.issn
              upd.issn.push isn
          upd.retained = true if exists.retained isnt true
          upd.retention = rt
          if JSON.stringify(upd) isnt '{}'
            for en in exists.issn
              upd.issn.push(en) if typeof en is 'string' and en.length and en not in upd.issn
            jct_journal.update exists._id, upd
        else
          rec = retained: true, retention: rt, issn: rt.issn, publisher: rt.publisher, title: rt.journal
          jct_journal.insert rec
    console.log('Imported ' + counter)

  if issn
    issn = [issn] if typeof issn is 'string'
    res =
      route: 'retention' # this is actually only used as a subset of OAB permission self_archiving so far
      compliant: 'yes' # if not present then compliant but with author and funder quals - so what are the default funder quals?
      qualifications: [{'rights_retention_author_advice': ''}]
      issn: issn
      log: []

    if exists = jct_journal.find 'retained:true AND (issn.exact:"' + issn.join('" OR issn.exact:"') + '")'
      # https://github.com/antleaf/jct-project/issues/406 no qualification needed if retained is true. Position not used.
      delete res.qualifications
      res.log.push code: 'SA.Compliant'
    else
      # new log code algo states there should be an SA.Unknown, but given we default to 
      # compliant at the moment, I don't see a way to achieve that, so set as Compliant for now
      res.log.push(code: 'SA.Compliant') if res.log.length is 0
    return res
  else
    return jct_journal.count 'retained:true'


API.service.jct.oa_works = (issn, institution) ->
  issn = issn.split(',') if typeof issn is 'string'
  permsurl = 'https://api.openaccessbutton.org/permissions?meta=false&issn=' + (if typeof issn is 'string' then issn else issn.join(',')) + (if typeof institution is 'string' then '&ror=' + institution else if institution? and Array.isArray(institution) and institution.length then '&ror=' + institution.join(',') else '')
  perms = HTTP.call('GET', permsurl, {timeout:3000}).data
  return perms


API.service.jct.permission = (issn, institution, perms) ->
  issn = issn.split(',') if typeof issn is 'string'
  res =
    route: 'self_archiving'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    ror: institution
    funder: undefined
    log: []

  try
    if perms.best_permission?
      res.compliant = 'no' # set to no until a successful route through is found
      pb = perms.best_permission
      res.log.push code: 'SA.InOAB'
      lc = false
      pbls = [] # have to do these now even if can't archive, because needed for new API code algo values
      for l in pb.licences ? []
        pbls.push l.type
        if lc is false and l.type.toLowerCase().replace(/\-/g,'').replace(/ /g,'') in ['ccby','ccbysa','cc0','ccbynd']
          lc = l.type # set the first but have to keep going for new API codes algo
      if pb.can_archive
        if 'postprint' in pb.versions or 'publisher pdf' in pb.versions or 'acceptedVersion' in pb.versions or 'publishedVersion' in pb.versions
          # and Embargo is zero
          if typeof pb.embargo_months is 'string'
            try pb.embargo_months = parseInt pb.embargo_months
          if typeof pb.embargo_months isnt 'number' or pb.embargo_months is 0
            if lc
              res.log.push code: 'SA.OABCompliant', parameters: licence: pbls, embargo: (if pb.embargo_months? then [pb.embargo_months] else undefined), version: pb.versions
              res.compliant = 'yes'
            else if not pb.licences? or pb.licences.length is 0
              res.log.push code: 'SA.OABIncomplete', parameters: missing: ['licences']
              res.compliant = 'unknown'
            else
              res.log.push code: 'SA.OABNonCompliant', parameters: licence: pbls, embargo: (if pb.embargo_months? then [pb.embargo_months] else undefined), version: pb.versions
          else
            res.log.push code: 'SA.OABNonCompliant', parameters: licence: pbls, embargo: (if pb.embargo_months? then [pb.embargo_months] else undefined), version: pb.versions
        else
          res.log.push code: 'SA.OABNonCompliant', parameters: licence: pbls, embargo: (if pb.embargo_months? then [pb.embargo_months] else undefined), version: pb.versions
      else
        res.log.push code: 'SA.OABNonCompliant', parameters: licence: pbls, embargo: (if pb.embargo_months? then [pb.embargo_months] else undefined), version: pb.versions
    else
      res.log.push code: 'SA.NotInOAB'
  catch
    # Fixme: if we don't get an answer then we don't have the info, but this may not be strictly what we want.
    res.log.push code: 'SA.OABIncomplete', parameters: missing: ['licences']
    res.compliant = 'unknown'
  return res


API.service.jct.hybrid = (issn, institution, funder, oa_permissions) ->
  issn = issn.split(',') if typeof issn is 'string'
  res =
    route: 'hybrid'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    ror: institution
    funder: funder
    log: []

  if oa_permissions.best_permission?.issuer?.journal_oa_type?
    pb = oa_permissions.best_permission
    journal_type = pb.issuer.journal_oa_type
    if journal_type not in ['hybrid', 'transformative']
      res.compliant = 'no'
      res.log.push code: 'Hybrid.NotInOAW'
    else
      res.log.push code: 'Hybrid.InOAW'
      # get list of licences and matching license condition
      lc = false
      licences = [] # have to do these now even if can't archive, because needed for new API code algo values
      for l in pb.licences ? []
        licences.push l.type
        # TODO: Need to match with funder config
        if lc is false and l.type.toLowerCase().replace(/\-/g,'').replace(/ /g,'') in ['ccby','ccbysa','cc0','ccbynd']
          lc = l.type
      # check if license is compliant
      if lc
        res.log.push code: 'Hybrid.Compliant', parameters: licence: licences
        res.compliant = 'yes'
      else if not licences or licences.length is 0
        res.log.push code: 'Hybrid.Unknown', parameters: missing: ['licences']
        res.compliant = 'unknown'
      else
        res.log.push code: 'Hybrid.NonCompliant', parameters: licence: licences
  else
    res.log.push code: 'Hybrid.Unknown', parameters: missing: ['journal type']
    res.compliant = 'unknown'
  return res


# Calculate self archiving check. It combines, sa_prohibited, OA.works permission and rr checks
API.service.jct.sa = (journal, institution, funder, oa_permissions, check_retention=true, check_sa_prohibition=true) ->
  # Get SA prohibition
  if journal and check_sa_prohibition
    res_sa = API.service.jct.sa_prohibited journal, undefined
    if res_sa and res_sa.compliant is 'no'
      return res_sa

  # Get OA.Works permission
  rs = API.service.jct.permission journal, institution, oa_permissions

  # merge the qualifications and logs from SA prohibition into OA.Works permission
  rs.qualifications ?= []
  if res_sa.qualifications? and res_sa.qualifications.length
    for q in (if _.isArray(res_sa.qualifications) then res_sa.qualifications else [res_sa.qualifications])
      rs.qualifications.push(q)
  rs.log ?= []
  if res_sa.log? and res_sa.log.length
    for l in (if _.isArray(res_sa.log) then res_sa.log else [res_sa.log])
      rs.log.push(l)

  # check for retention
  if rs
    _rtn = {}
    for r in (if _.isArray(rs) then rs else [rs])
      if r.compliant isnt 'yes' and check_retention
        # only check retention if the funder allows it - and only if there IS a funder
        # funder allows if their rights retention date
        if journal and funder? and fndr = API.service.jct.funders funder
          r.funder = funder
          # if retentionAt is in past - active - https://github.com/antleaf/jct-project/issues/437
          if fndr.retentionAt? and fndr.retentionAt < Date.now()
            r.log.push code: 'SA.FunderRRActive'
            # 26032021, as per https://github.com/antleaf/jct-project/issues/380
            # rights retention qualification disabled
            #r.qualifications ?= []
            #r.qualifications.push 'rights_retention_funder_implementation': funder: funder, date: moment(fndr.retentionAt).format 'YYYY-MM-DD'
            # retention is a special case on permissions, done this way so can be easily disabled for testing
            _rtn[journal] ?= API.service.jct.retention journal
            r.compliant = _rtn[journal].compliant
            r.log.push(lg) for lg in _rtn[journal].log
            if _rtn[journal].qualifications? and _rtn[journal].qualifications.length
              r.qualifications ?= []
              r.qualifications.push(ql) for ql in _rtn[journal].qualifications
          else
            r.log.push code: 'SA.FunderRRNotActive'
  return rs


API.service.jct.fully_oa = (issn) ->
  issn = issn.split(',') if typeof issn is 'string'
  res =
    route: 'fully_oa'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    log: []

  if issn
    if ind = jct_journal.find 'indoaj:true AND (issn.exact:"' + issn.join('" OR issn.exact:"') + '")'
      res.log.push code: 'FullOA.InDOAJ'
      db = ind.doaj.bibjson
      # Publishing License	bibjson.license[].type	bibjson.license[].type	CC BY, CC BY SA, CC0	CC BY ND
      pl = false
      lics = []
      if db.license? and db.license.length
        for bl in db.license
          if typeof bl?.type is 'string'
            if bl.type.toLowerCase().trim().replace(/ /g,'').replace(/-/g,'') in ['ccby','ccbysa','cc0','ccbynd']
              pl = bl.type if pl is false # only the first suitable one
            lics.push bl.type # but have to keep going and record them all now for new API code returns values
      if not db.license?
        res.log.push code: 'FullOA.Unknown', parameters: missing: ['license']
      else if pl
        res.log.push code: 'FullOA.Compliant', parameters: licence: lics
        res.compliant = 'yes'
      else
        res.log.push code: 'FullOA.NonCompliant', parameters: licence: lics
        res.compliant = 'no'
    # extra parts used to go here, but have been removed due to algorithm simplification.
    else
      res.log.push code: 'FullOA.NotInDOAJ'
      res.compliant = 'no'

    if res.compliant isnt 'yes'
      # check if there is an open application for the journal to join DOAJ, if it wasn't already there
      if pfd = jct_journal.find 'doajinprogress:true AND (issn.exact:"' + issn.join('" OR issn.exact:"') + '")'
        if true # if an application, has to have applied within 6 months
          res.log.push code: 'FullOA.InProgressDOAJ'
          res.compliant = 'yes'
          res.qualifications = [{doaj_under_review: {}}]
        else
          res.log.push code: 'FullOA.NotInProgressDOAJ' # there is actually an application, but it is too old
          res.compliant = 'no'
      else
        res.log.push code: 'FullOA.NotInProgressDOAJ' # there is no application, so still may or may not be compliant

  return res


# https://www.coalition-s.org/plan-s-funders-implementation/
_funders = []
_last_funders = Date.now()
API.service.jct.funders = (id, refresh) ->
  if refresh or _funders.length is 0 or _last_funders > (Date.now() - 604800000) # if older than a week
    _last_funders = Date.now()
    _funders = []
    for r in API.service.jct.table2json 'https://www.coalition-s.org/plan-s-funders-implementation/'
      rec = 
        funder: r['cOAlition S organisation (funder)']
        launch: r['Launch date for implementing  Plan S-aligned OA policy']
        application: r['Application of Plan S principles ']
        retention: r['Rights Retention Strategy Implementation']
      try rec.funder = rec.funder.replace('&amp;','&')
      for k of rec
        if rec[k]?
          rec[k] = rec[k].trim()
          if rec[k].indexOf('<a') isnt -1
            rec.url ?= []
            rec.url.push rec[k].split('href')[1].split('=')[1].split('"')[1]
            rec[k] = (rec[k].split('<')[0] + rec[k].split('>')[1].split('<')[0] + rec[k].split('>').pop()).trim()
        else
          delete rec[k]
      if rec.retention
        if rec.retention.indexOf('Note:') isnt -1
          rec.notes ?= []
          rec.notes.push rec.retention.split('Note:')[1].replace(')','').trim()
          rec.retention = rec.retention.split('Note:')[0].replace('(','').trim()
        rec.retentionAt = moment('01012021','DDMMYYYY').valueOf() if rec.retention.toLowerCase().indexOf('early adopter') isnt -1
      try rec.startAt = moment(rec.launch, 'Do MMMM YYYY').valueOf()
      delete rec.startAt if JSON.stringify(rec.startAt) is 'null'
      if not rec.startAt? and rec.launch?
        rec.notes ?= []
        rec.notes.push rec.launch
      try rec.id = rec.funder.toLowerCase().replace(/[^a-z0-9]/g,'')
      _funders.push(rec) if rec.id?
    
  if id?
    for e in _funders
      if e.id is id
        return e
  return _funders


API.service.jct.journals = {}
API.service.jct.journals.import = (refresh) ->
  # first see if DOAJ file has updated - if so, do a full journal import
  # doaj only updates their journal dump once a week so calling journal import
  # won't actually do anything if the dump file name has not changed since last run 
  # or if a refresh is called
  fldr = '/tmp/jct_doaj' + (if API.settings.dev then '_dev' else '') + '/'
  if not fs.existsSync fldr
    fs.mkdirSync fldr
  ret = false
  prev = false
  current = false
  fs.writeFileSync fldr + 'doaj.tar', HTTP.call('GET', 'https://doaj.org/public-data-dump/journal', {npmRequestOptions:{encoding:null}}).content
  tar.extract file: fldr + 'doaj.tar', cwd: fldr, sync: true # extracted doaj dump folders end 2020-10-01
  console.log 'got DOAJ journals dump'
  for f in fs.readdirSync fldr # readdir alphasorts, so if more than one in tmp then last one will be newest
    if f.indexOf('doaj_journal_data') isnt -1
      if prev
        try fs.unlinkSync fldr + prev + '/journal_batch_1.json'
        try fs.rmdirSync fldr + prev
      prev = current
      current = f
  if current and (prev or refresh)
    console.log 'DOAJ journal dump ' + current + ' is suitable for ingest, getting crossref first'

    # get everything from crossref
    removed = false
    total = 0
    counter = 0
    batch = []
    error_count = 0
    while (total is 0 or counter < total) and error_count < 10
      if batch.length >= 10000 or (removed and batch.length >= 5000)
        if not removed
          # makes a shorter period of lack of records to query
          # there will still be a period of 5 to 10 minutes where not all journals will be present
          # but, since imports only occur once a day to every few days depending on settings, and 
          # responses should be cached at cloudflare anyway, this should not affect anyone as long as 
          # imports are not often run during UK/US business hours
          jct_journal.remove '*'
          console.log 'Removing old journal records'
          future = new Future()
          Meteor.setTimeout (() -> future.return()), 10000
          future.wait()
          removed = true
        console.log 'Importing crossref ' + counter
        jct_journal.insert batch
        batch = []
      try
        url = 'https://api.crossref.org/journals?offset=' + counter + '&rows=' + 1000
        console.log 'getting from crossref journals ' + url
        res = HTTP.call 'GET', url, {headers: {'User-Agent': 'Journal Checker Tool; mailto: jct@cottagelabs.zendesk.com'}}
        total = res.data.message['total-results'] if total is 0
        for rec in res.data.message.items
          if rec.ISSN and rec.ISSN.length and typeof rec.ISSN[0] is 'string'
            rec.crossref = true
            rec.issn = []
            for i in rec.ISSN
              rec.issn.push(i) if typeof i is 'string' and i.length and i not in rec.issn
            rec.dois = rec.counts?['total-dois']
            if rec.breakdowns?['dois-by-issued-year']?
              rec.years = []
              for yr in rec.breakdowns['dois-by-issued-year']
                rec.years.push(yr[0]) if yr.length is 2 and yr[0] not in rec.years
              rec.years.sort()
            if not rec.years? or not rec.years.length or not rec.dois
              rec.discontinued = true
            else
              thisyear = new Date().getFullYear()
              if thisyear not in rec.years and (thisyear-1) not in rec.years and (thisyear-2) not in rec.years and (thisyear-3) not in rec.years
                rec.discontinued = true
            batch.push rec
        counter += 1000
      catch err
        error_count += 1
        future = new Future()
        Meteor.setTimeout (() -> future.return()), 2000 # wait 2s on probable crossref downtime
        future.wait()
    if batch.length
      jct_journal.insert batch
      batch = []
    if error_count >= 10
      console.log 'Crossref import had ' + error_count + ' errors. Backing off. Imported ' + batch.length + ' of ' + total + ' records.'

    # then load the DOAJ data from the file (crossref takes priority because it has better metadata for spotting discontinuations)
    # only about 20% of the ~15k are not already in crossref, so do updates then bulk load the new ones
    console.log 'Importing from DOAJ journal dump ' + current
    imports = 0
    for rec in JSON.parse fs.readFileSync fldr + current + '/journal_batch_1.json'
      imports += 1
      console.log('DOAJ dump import ' + imports) if imports % 1000 is 0
      qr = if typeof rec.bibjson.pissn is 'string' then 'issn.exact:"' + rec.bibjson.pissn + '"' else ''
      if typeof rec.bibjson.eissn is 'string'
        qr += ' OR ' if qr isnt ''
        qr += 'issn.exact:"' + rec.bibjson.eissn + '"'
      if exists = jct_journal.find qr
        upd = doaj: rec
        upd.indoaj = true
        upd.discontinued = true if rec.bibjson.discontinued_date or rec.bibjson.is_replaced_by
        upd.issn = [] # DOAJ ISSN data overrides crossref because we've seen errors in crossref that are correct in DOAJ such as 1474-9728
        upd.issn.push(rec.bibjson.pissn.toUpperCase()) if typeof rec.bibjson.pissn is 'string' and rec.bibjson.pissn.length and rec.bibjson.pissn.toUpperCase() not in upd.issn
        upd.issn.push(rec.bibjson.eissn.toUpperCase()) if typeof rec.bibjson.eissn is 'string' and rec.bibjson.eissn.length and rec.bibjson.eissn.toUpperCase() not in upd.issn
        jct_journal.update exists._id, upd
      else
        nr = doaj: rec, indoaj: true
        nr.title ?= rec.bibjson.title
        nr.publisher ?= rec.bibjson.publisher.name if rec.bibjson.publisher?.name?
        nr.discontinued = true if rec.bibjson.discontinued_date or rec.bibjson.is_replaced_by
        nr.issn ?= []
        nr.issn.push(rec.bibjson.pissn.toUpperCase()) if typeof rec.bibjson.pissn is 'string' and rec.bibjson.pissn.toUpperCase() not in nr.issn
        nr.issn.push(rec.bibjson.eissn.toUpperCase()) if typeof rec.bibjson.eissn is 'string' and rec.bibjson.eissn.toUpperCase() not in nr.issn
        batch.push nr
    if batch.length
      jct_journal.insert batch
      batch = []

    # get new doaj inprogress data if the journals load processed some doaj
    # journals (otherwise we're between the week-long period when doaj doesn't update)
    # and if doaj did update, load them into the catalogue too - there's only a few hundred so can check them for crossref dups too
    r = HTTP.call 'GET', 'https://doaj.org/jct/inprogress?api_key=' + API.settings.service.jct.doaj.apikey
    console.log 'Loading DOAJ inprogress records'
    inpc = 0
    for rec in JSON.parse r.content
      inpc += 1
      console.log('DOAJ inprogress ' + inpc) if inpc % 100 is 0
      issns = []
      issns.push(rec.pissn.toUpperCase()) if typeof rec.pissn is 'string' and rec.pissn.length
      issns.push(rec.eissn.toUpperCase()) if typeof rec.eissn is 'string' and rec.eissn.length
      if exists = jct_journal.find 'issn.exact:"' + issns.join('" OR issn.exact:"') + '"'
        if not exists.indoaj # no point adding an application if already in doaj, which should be impossible, but check anyway
          upd = doajinprogress: true, doajprogress: rec
          nissns = []
          for isn in issns
            nissns.push(isn) if isn not in nissns and isn not in exists.issn
          if nissns.length
            upd.issn = _.union exists.issn, nissns
          jct_journal.update exists._id, upd
        else
          console.log 'DOAJ in progress application already in DOAJ for ' + issns.join(', ')
      else
        nr = doajprogress: rec, issn: issns, doajinprogress: true
        batch.push nr
    if batch.length
      jct_journal.insert batch
      batch = []
    return jct_journal.count()
  else
    return 0
  # when importing TJ or TA data, add any journals not yet known about
  

API.service.jct.import = (refresh) ->
  res = {}
  if jct_journal
    res = previously: jct_journal.count(), presently: undefined, started: Date.now()
    res.newest = jct_agreement.find '*', true
  if refresh or res.newest?.createdAt < Date.now()-86400000
    # run all imports necessary for up to date data
    console.log 'Starting JCT imports'

    console.log 'Starting journals import'
    res.journals = API.service.jct.journals.import refresh # takes about 10 mins depending how crossref is feeling
    console.log 'JCT journals imported ' + res.journals
  
    console.log 'Starting TJs import'
    res.tj = API.service.jct.tj undefined, true
    console.log 'JCT import TJs complete'

    console.log 'Starting sa prohibited data import'
    res.retention = API.service.jct.sa_prohibited undefined, true
    console.log 'JCT import sa prohibited data complete'

    console.log 'Starting retention data import'
    res.retention = API.service.jct.retention undefined, true
    console.log 'JCT import retention data complete'

    console.log 'Starting funder data import'
    res.funders = API.service.jct.funders undefined, true
    res.funders = res.funders.length if _.isArray res.funders
    console.log 'JCT import funders complete'

    console.log 'Starting TAs data import'
    res.ta = API.service.jct.ta.import false # this is the slowest, takes about twenty minutes
    console.log 'JCT import TAs complete'

    console.log 'Starting Funder db config import'
    API.service.jct.funder_config.import()
    console.log 'JCT import Funder db config complete'

    console.log 'Starting Funder db language import'
    API.service.jct.funder_language.import()
    console.log 'JCT import Funder db language complete'

    # check the mappings on jct_journal, jct_agreement, any others that get used and changed during import
    # include a warning in the email if they seem far out of sync
    # and include the previously and presently count, they should not be too different
    res.presently = jct_journal.count()
    res.ended = Date.now()
    res.took = res.ended - res.started
    res.minutes = Math.ceil res.took/60000
    if res.mapped = JSON.stringify(jct_journal.mapping()).indexOf('dynamic_templates') isnt -1
      res.mapped = JSON.stringify(jct_agreement.mapping()).indexOf('dynamic_templates') isnt -1
  
    API.service.jct.mail
      subject: 'JCT import complete'
      text: JSON.stringify res, '', 2

  return res

_jct_import = () ->
  try API.service.jct.funders undefined, true # get the funders at startup
  if API.settings.service?.jct?.import isnt false # so defaults to run if not set to false in settings
    console.log 'Setting up a daily import check which will run an import if it is day ' + API.settings.service.jct.import_day
    # if later updates are made to run this on a cluster again, make sure that only one server runs this (e.g. use the import setting above where necessary)
    Meteor.setInterval () ->
      today = new Date()
      if today.getDay() is API.settings.service.jct.import_day
        # if import_day number matches, run import. Days are numbered 0 to 6, Sun to Sat
        console.log 'Starting day ' + API.settings.service.jct.import_day + ' import'
        API.service.jct.import()
    , 86400000
Meteor.setTimeout _jct_import, 5000


API.service.jct.unknown = (res, funder, journal, institution, send) ->
  if res?
    # it may not be worth saving these seperately if compliance result caching is on, but for now will keep them
    r = _.clone res
    r._id = (funder ? '') + '_' + (journal ? '') + '_' + (institution ? '') # overwrite dups
    r.counter = 1
    if ls = jct_unknown.get r._id
      r.lastsend = ls.lastsend
      r.counter += ls.counter ? 0
    try jct_unknown.insert r
  cnt = jct_unknown.count()
  if send
    try
      cnt = 0
      start = false
      end = false
      if typeof send isnt 'boolean'
        start = send
        q = 'createdAt:>' + send
      else if lf = jct_unknown.find 'lastsend:*', {sort: {lastsend: {order: 'desc'}}}
        start = lf.lastsend
        q = 'createdAt:>' + lf.lastsend
      else
        q = '*'
      last = false
      for un in (jct_unknown.fetch q, {newest: false})
        start = un.createdAt if start is false
        end = un.createdAt
        last = un
        cnt += 1
      if last isnt false
        jct_unknown.update last._id, lastsend: Date.now()
        durl = 'https://' + (if API.settings.dev then 'api.jct.cottagelabs.com' else 'api.journalcheckertool.org') + '/unknown/' + start + '/' + end + '.csv'
        API.service.jct.feedback name: 'unknowns', email: 'jct@cottagelabs.com', subject: 'JCT system reporting unknowns', feedback: durl
  return cnt

Meteor.setTimeout (() -> API.service.jct.unknown(undefined, undefined, undefined, undefined, true)), 86400000 # send once a day


API.service.jct.feedback = (params={}) ->
  if typeof params.name is 'string' and typeof params.email is 'string' and typeof params.feedback is 'string' and (not params.context? or typeof params.context is 'object')
    API.service.jct.mail
      from: if params.email.indexOf('@') isnt -1 and params.email.indexOf('.') isnt -1 then params.email else 'nobody@cottagelabs.com'
      subject: params.subject ? params.feedback.substring(0,100) + if params.feedback.length > 100 then '...' else ''
      text: (if API.settings.dev then '(dev)\n\n' else '') + params.feedback + '\n\n' + (if params.subject then '' else JSON.stringify params, '', 2)
    return true
  else
    return false


API.service.jct.csv = (rows) ->
  if Array.isArray(rows) and rows.length
    header = ''
    fields = []
    for r in rows
      for k of r
        if k not in fields
          fields.push k
          header += ',' if header isnt ''
          header += '"' + k.replace(/\"/g, '') + '"'
    res = ''
    for rr in rows
      res += '\n' if res isnt ''
      ln = ''
      for f in fields
        ln += ',' if ln isnt ''
        ln += '"' + JSON.stringify(rr[f] ? '').replace(/\"/g, '') + '"'
      res += ln
    return header + '\n' + res
  else
    return ''


API.service.jct.csv2json = Async.wrap (content, callback) ->
  content = HTTP.call('GET', content).content if content.indexOf('http') is 0
  csvtojson().fromString(content).then (result) -> return callback null, result

API.service.jct.table2json = (content) ->
  content = HTTP.call('GET', content).content if content.indexOf('http') is 0 # TODO need to try this without puppeteer
  if content.indexOf('<table') isnt -1
    content = '<table' + content.split('<table')[1]
  else if content.indexOf('<TABLE') isnt -1
    content = '<TABLE' + content.split('<TABLE')[1]
  if content.indexOf('</table') isnt -1
    content = content.split('</table')[0] + '</table>'
  else if content.indexOf('</TABLE') isnt -1
    content = content.split('</TABLE')[1] + '</TABLE>'
  content = content.replace(/\r?\n|\r/g,'')
  ths = content.match(/<th.*?<\/th/gi)
  headers = []
  results = []
  if ths?
    for h in ths
      str = h.replace(/<th.*?>/i,'').replace(/<\/th.*?/i,'').replace(/<.*?>/gi,'').replace(/\s\s+/g,' ').trim()
      str = 'UNKNOWN' if str.replace(/ /g,'').length is 0
      headers.push str
  for r in content.split('<tr')
    if r.toLowerCase().indexOf('<th') is -1
      result = {}
      row = r.replace(/.*?>/i,'').replace(/<\/tr.*?/i,'')
      vals = row.match(/<td.*?<\/td/gi)
      keycounter = 0
      for d of vals
        val = vals[d].replace(/<.*?>/gi,'').replace('</td','')
        if headers.length > keycounter
          result[headers[keycounter]] = val
        keycounter += 1
        if vals[d].toLowerCase().indexOf('colspan') isnt -1
          try
            keycounter += parseInt(vals[d].toLowerCase().split('colspan')[1].split('>')[0].replace(/[^0-9]/,''))-1
      delete result.UNKNOWN if result.UNKNOWN?
      if not _.isEmpty result
        results.push result
  return results


API.service.jct.mail = (opts) ->
  ms = API.settings.mail ? {} # need domain and apikey
  mailer = mailgun domain: ms.domain, apiKey: ms.apikey
  opts.from ?= 'jct@cottagelabs.com' # ms.from ? 
  opts.to ?= 'jct@cottagelabs.zendesk.com' # ms.to ? 
  opts.to = opts.to.join(',') if typeof opts.to is 'object'
  #try HTTP.call 'POST', 'https://api.mailgun.net/v3/' + ms.domain + '/messages', {params:opts, auth:'api:'+ms.apikey}
  # opts.attachment can be a string which is assumed to be a filename to attach, or a Buffer
  # https://www.npmjs.com/package/mailgun-js
  if typeof opts.attachment is 'object'
    if opts.filename
      fn = opts.filename
      delete opts.filename
    else
      fn = 'data.csv'
    att = API.service.jct.csv opts.attachment
    opts.attachment = new mailer.Attachment filename: fn, contentType: 'text/csv', data: Buffer.from att, 'utf8'
  console.log 'Sending mail to ' + opts.to
  mailer.messages().send opts
  return true


API.service.jct.test = (params={}) ->
  # This automates the tests and the outcomes defined in the JCT Integration Tests spreadsheet (sheet JCT)
  # Expected JCT Outcome, is what the outcome should be based on reading the information within journal, institution and funder data.
  # Actual JCT Outcome is what was obtained by walking through the algorithm under the assumption that
  # the publicly available information is within the JCT data sources.

  _get_val = (cell, type = false) ->
    val = undefined
    try
      if typeof cell is 'string'
        val = cell.trim()
      if type is 'array'
        if ',' in val
          values = val.split(',')
          for v, index in values
            values[index] = v.trim()
          val = values
        if not Array.isArray(val)
          val = [val]
      if type in ['number', 'number_to_boolean']
        val = parseInt val
        if type is 'number_to_boolean'
          if val > 0
            val = true
          else
            val = false
    catch
      val = undefined
    return val

  _get_query_params = (test) ->
    query =
      issn: _get_val(test['ISSN'])
      funder: _get_val(test['Funder ID'])
      ror: _get_val(test['ROR'])
    return query

  _get_expected_cards = (test) ->
    expected_cards = []
    for cell in ['Card 1', 'Card 2', 'Card 3', 'Card 4']
      val = _get_val(test[cell])
      if val
        expected_cards.push(val)
    return expected_cards

  _initialise_result = (test) ->
    res =
      id: _get_val(test['Test ID'], 'number')
      journal:
        issn: _get_val(test['ISSN'])
        expected: _get_val(test['Journal Name'])
        got: undefined
        outcome: undefined
      funder:
        id: _get_val(test['Funder ID'])
        expected: _get_val(test['Funder Name'])
        got: undefined
        outcome: undefined
      institution:
        ror: _get_val(test['ROR'])
        expected: _get_val(test['Institution'])
        got: undefined
        outcome: undefined
      route:
        fully_oa:
          expected: _get_val(test['Fully OA'], 'number_to_boolean')
          got: undefined
          outcome: undefined
          log_codes:
            expected: _get_val(test['Fully OA log codes'], 'array')
            got: undefined
            outcome: undefined
        ta:
          expected: _get_val(test['TA'], 'number_to_boolean')
          got: undefined
          outcome: undefined
          log_codes:
            expected: _get_val(test['TA log codes'], 'array')
            got: undefined
            outcome: undefined
        tj:
          expected: _get_val(test['TJ'], 'number_to_boolean')
          got: undefined
          outcome: undefined
          log_codes:
            expected: _get_val(test['TJ log codes'], 'array')
            got: undefined
            outcome: undefined
        self_archiving:
          expected: _get_val(test['SA'], 'number_to_boolean')
          got: undefined
          outcome: undefined
          log_codes:
            expected: _get_val(test['SA log codes'], 'array')
            got: undefined
            outcome: undefined
        hybrid:
          expected: _get_val(test['Hybrid'], 'number_to_boolean')
          got: undefined
          outcome: undefined
          log_codes:
            expected: _get_val(test['Hybrid log codes'])
            got: undefined
            outcome: undefined
      cards:
        expected: _get_expected_cards(test)
        got: undefined
        outcome: undefined
      result:
        outcome: true
        pass: 0
        fail: 0
        warning: 0
        total: 0
        message: []
    return res

  _initialise_final_result = () ->
    result =
      outcome: true
      pass: 0
      fail: 0
      warning: 0
      total: 0
      message: []
      test_result: []
    return result

  _test_equal = (expected, got) ->
    if typeof expected is 'string'
      if not typeof got is 'string'
        got = got.toString()
      return expected.toLowerCase() == got.toLowerCase()
    else if typeof expected is 'boolean'
      if typeof got isnt 'boolean'
        return false
      return got is expected
    else
      if not _.isArray(expected) then [expected] else expected
      if not _.isArray(got) then [got] else got
      if got.length is expected.length and expected.every (elem) -> elem in got
        return true
    return false

  _match_query = (param, output, res) ->
    if res[param].expected isnt undefined
      res[param].outcome = false
      if output.request[param] and output.request[param].length and output.request[param][0].title?
        res[param].got =  _get_val(output.request[param][0].title)
        res[param].outcome = _test_equal(res[param].expected, res[param].got)
    return

  _test_compliance = (route_name, output_result, res) ->
    # get compliance
    if output_result.compliant?
      ans = false
      if output_result.compliant is "yes"
        ans = true
      res.route[route_name].got = ans
    if res.route[route_name].expected isnt undefined
      res.route[route_name].outcome = _test_equal(res.route[route_name].expected, res.route[route_name].got)
    return

  _test_log_codes = (route_name, output_result, res) ->
    # get log codes
    expected = res.route[route_name].log_codes.expected
    if expected is undefined or not expected
      expected = []
    if not Array.isArray(expected)
      expected = [expected]
    got = []
    if output_result.log? and output_result.log.length
      for log in output_result.log
        if log.code? and log.code
          got.push(log.code)
    res.route[route_name].log_codes.got = got
    res.route[route_name].log_codes.outcome = _test_equal(expected, got)
    return

  _test_route = (output, res) ->
    if output.results? and output.results.length
      for output_result in output.results
        route_name = output_result.route
        if res.route[route_name]?
          _test_compliance(route_name, output_result, res)
          _test_log_codes(route_name, output_result, res)
    return

  _test_cards = (output, res) ->
    # get expected cards
    expected = res.cards.expected
    got = []
    if output.cards? and output.cards.length
      for card in output.cards
        if card.id? and card.id
          got.push(card.id)
      res.cards.got = got
    res.cards.outcome = _test_equal(expected, got)
    return

  _add_message = (type, id, name, got, expected) ->
    message = type + ': ' + id + ' - ' + name + ' - ' + 'Got: ' + JSON.stringify(got) + ' Expected: ' + JSON.stringify(expected)
    return message

  _add_query_outcome = (param, res) ->
    if res[param].outcome isnt true
      res.result.message.push(_add_message('Warning', res.id, 'Query param ' + param, res[param].got, res[param].expected))

  _add_compliance_outcome = (param, res) ->
    res.result.total += 1
    if typeof res.route[param].outcome is 'boolean'
      res.result.outcome = res.result.outcome and res.route[param].outcome
    if res.route[param].outcome is undefined
      res.result.warning += 1
      res.result.message.push(_add_message('Warning', res.id, param + ' compliance', res.route[param].got, res.route[param].expected))
    else if res.route[param].outcome is true
      res.result.pass += 1
      # res.result.message.push(_add_message('Debug', res.id, param + ' compliance', res.route[param].got, res.route[param].expected))
    else
      res.result.fail += 1
      res.result.message.push(_add_message('Error', res.id, param + ' compliance', res.route[param].got, res.route[param].expected))

  _add_log_codes_outcome = (param, res) ->
    res.result.total += 1
    if typeof res.route[param].log_codes.outcome is 'boolean'
      res.result.outcome = res.result.outcome and res.route[param].log_codes.outcome
    if res.route[param].log_codes.outcome is undefined
      res.result.warning += 1
      res.result.message.push(_add_message('Warning', res.id, param + ' log codes ', res.route[param].log_codes.got, res.route[param].log_codes.expected))
    else if res.route[param].log_codes.outcome is true
      res.result.pass += 1
      # res.result.message.push(_add_message('Debug', res.id, param + ' log codes ', res.route[param].log_codes.got, res.route[param].log_codes.expected))
    else
      res.result.fail += 1
      res.result.message.push(_add_message('Error', res.id, param + ' log codes ', res.route[param].log_codes.got, res.route[param].log_codes.expected))

  _add_cards_outcome = (res) ->
    res.result.total += 1
    if typeof res.cards.outcome is 'boolean'
      res.result.outcome = res.result.outcome and res.cards.outcome
    if res.cards.outcome is undefined
      res.result.warning += 1
      res.result.message.push(_add_message('Warning', res.id, 'cards', res.cards.got, res.cards.expected))
    else if res.cards.outcome is true
      res.result.pass += 1
      # res.result.message.push(_add_message('Debug', res.id, 'cards', res.cards.got, res.cards.expected))
    else
      res.result.fail += 1
      res.result.message.push(_add_message('Error', res.id, 'cards', res.cards.got, res.cards.expected))

  _add_outcome = (res) ->
    # match query - journal
    _add_query_outcome('journal', res)
    _add_query_outcome('funder', res)
    _add_query_outcome('institution', res)
    for route_name, route_outcomes of res.route
      _add_compliance_outcome(route_name, res)
      _add_log_codes_outcome(route_name, res)
    _add_cards_outcome(res)

  _add_final_outcome = (res, final_result) ->
    final_result.total += 1
    if typeof res.result.outcome is 'boolean'
      final_result.outcome = final_result.outcome and res.result.outcome
    if res.result.outcome is undefined
      final_result.warning += 1
      Array::push.apply final_result.message, res.result.message
    else if res.result.outcome is true
      final_result.pass += 1
    else if res.result.outcome is false
      final_result.fail += 1
      Array::push.apply final_result.message, res.result.message
    final_result.test_result.push(res)

  # original test sheet
  test_sheet= "https://docs.google.com/spreadsheets/d/e/2PACX-1vTjuuobH3m7Bq5ztsKnue5W7ieqqsBYOm5sX17_LSuQjkyNTozvOED5E0hvazWRjIfSW5xvhRSdNLBF/pub?gid=0&single=true&output=csv"
  # Test sheet with my extensions
  # test_sheet = "https://docs.google.com/spreadsheets/d/e/2PACX-1vRW1YDHv4vu-7BexRKXWVd6HpD8ohXNvibj6vF_HP7H8YsBu6Yy1NcANXjg4E6lI-tIiImR2lhVKF0L/pub?gid=0&single=true&output=csv"

  console.log 'Getting list of tests'
  tests = API.service.jct.csv2json test_sheet
  console.log 'Retrieved ' + tests.length + ' tests from sheet'

  final_result = _initialise_final_result()
  for test in tests
    query = _get_query_params(test)
    res = _initialise_result(test)
    console.log('Doing test ' + res.id)
    if query.issn and query.funder and query.ror
      output = API.service.jct.calculate {funder: query.funder, issn: query.issn, ror: query.ror}
      for match in ['funder', 'journal', 'institution']
        _match_query(match, output, res)
      _test_route(output, res)
      _test_cards(output, res)
      _add_outcome(res)
    _add_final_outcome(res, final_result)
  return final_result

# return the funder config for an id. Import the data if refresh is true
API.service.jct.funder_config = (id, refresh) ->
  if refresh
    console.log('Got refresh - importing funder config')
    Meteor.setTimeout (() => API.service.jct.funder_config.import()), 1
    return true
  if id
    rec = jct_funder_config.find 'id.exact:"' + id.toLowerCase().trim() + '"'
    if rec
      return rec
    return {}
  else
    return total: jct_funder_config.count()


# For each funder in jct-funderdb repo, get the final funder configuration
# The funder's specific config file gets merged with the default config file, to create the final config file
# This is saved in elastic search
API.service.jct.funder_config.import = () ->
  funderdb_path = path.join(process.env.PWD, API.settings.funderdb)
  default_config_file = path.join(funderdb_path, 'default', 'config.yml')
  default_config = jsYaml.load(fs.readFileSync(default_config_file, 'utf8'));
  funders_config = []
  # For each funder in directory
  for f in fs.readdirSync funderdb_path
    # parse and get the merged config file if it isn't default
    if f isnt 'default'
      funder_config_file = path.join(funderdb_path, f, 'config.yml')
      if fs.existsSync funder_config_file
        funder_config = jsYaml.load(fs.readFileSync(funder_config_file, 'utf8'));
        merged_config = _merge_funder_config(default_config, funder_config)
        funders_config.push(merged_config)
  if funders_config.length
    console.log 'Removing and reloading ' + funders_config.length + ' funders configuration'
    jct_funder_config.remove '*'
    jct_funder_config.insert funders_config
  return

# return the funder language for an id. Import the data if refresh is true
API.service.jct.funder_language = (id, refresh) ->
  if refresh
    console.log('Got refresh - importing funder language files')
    Meteor.setTimeout (() => API.service.jct.funder_language.import()), 1
    return true
  if id
    rec = jct_funder_language.find 'id.exact:"' + id.toLowerCase().trim() + '"'
    if rec
      return rec
    return {}
  else
    return total: jct_funder_language.count()

# For each funder in jct-funderdb repo, get the final funder language file
# The funder's specific language files get merged with the default language files, to create the final language file
# This is saved in elastic search
API.service.jct.funder_language.import = () ->
  funderdb_path = path.join(process.env.PWD, API.settings.funderdb)
  default_lang_files_path = path.join(funderdb_path, 'default', 'lang')
  default_language = _flatten_yaml_files(default_lang_files_path)
  funders_language = []
  for f in fs.readdirSync funderdb_path
    # parse and get the merged config file if it isn't default
    if f isnt 'default'
      funder_lang_files_path = path.join(funderdb_path, f, 'lang')
      if fs.existsSync funder_lang_files_path
        merged_lang = _merge_language_files(default_language, funder_lang_files_path)
        merged_lang['id'] = f
        funders_language.push(merged_lang)
      else
        merged_lang = JSON.parse(JSON.stringify(default_language))
        merged_lang['id'] = f
        funders_language.push(merged_lang)
  if funders_language.length
    console.log 'Removing and reloading ' + funders_language.length + ' funders language files'
    jct_funder_language.remove '*'
    jct_funder_language.insert funders_language
  return

_merge_funder_config = (default_config, funder_config) ->
  result = _jct_object_merge(default_config, funder_config)
  return result

_merge_language_files = (default_language, language_files_path) ->
  funder_lang = _flatten_yaml_files(language_files_path)
  result = _jct_object_merge(default_language, funder_lang)
  return result

_jct_object_merge = (default_object, specific_object) ->
  result = JSON.parse(JSON.stringify(default_object)) # deep copy object
  for key in Object.keys(specific_object)
    # If specific_object[key] is an object and the key exists in default_object
    if Match.test(specific_object[key], Object)
      if key in Object.keys(default_object)
        result[key] = _jct_object_merge(default_object[key], specific_object[key])
      else
        result[key] = specific_object[key]
    else
      result[key] = specific_object[key]
  return result

_flatten_yaml_files = (lang_files_path) ->
  flattened_config = {}
  if not fs.existsSync lang_files_path
    return flattened_config
  if not fs.lstatSync(lang_files_path).isDirectory()
    return flattened_config
  for sub_file_name in fs.readdirSync lang_files_path
    sub_file_path = path.join(lang_files_path, sub_file_name)
    if fs.existsSync(sub_file_path) && fs.lstatSync(sub_file_path).isDirectory()
      flattened_config[sub_file_name] = _flatten_yaml_files(sub_file_path)
    else
      menu = sub_file_name.split('.')[0]
      flattened_config[menu] = jsYaml.load(fs.readFileSync(sub_file_path, 'utf8'));
  return flattened_config

_cards_for_display = (funder_config, results) ->
  _hasQualification = (path) ->
    parts = path.split(".")
    if results and results.length
      for r in results
        if parts[0] is r.route
          if r.qualifications? and r.qualifications.length
            for q in r.qualifications
              if parts[1] of q # key is in q
                return true
    return false

  _matches_qualifications = (qualifications) ->
    if not qualifications
      return true
    if qualifications.must? and qualifications.must.length
      for m_q in qualifications.must
        return false if not _hasQualification(m_q)
    if qualifications.not? and qualifications.not.length
      for n_q in qualifications.not
        return false if _hasQualification(n_q)
    if qualifications.or? and qualifications.or.length
      for o_q in qualifications.or
        return true if _hasQualification(oq)
      return false
    return true

  _matches_routes = (routes, compliantRoutes) ->
    if not routes
      return true
    if routes.must? and routes.must.length
      for m_r in routes.must
        if m_r not in compliantRoutes
          return false
    if routes.not? and routes.not.length
      for n_r in routes.not
        if n_r in compliantRoutes
          return false
    if routes['or']? and routes['or'].length
      for o_r in routes['or']
        if o_r in compliantRoutes
          return true
      return false
    return true

  _matches = (cardConfig, compliantRoutes) ->
    _matches_routes(cardConfig.match_routes, compliantRoutes) &&
      _matches_qualifications(cardConfig.match_qualifications);

  # compliant routes
  compliantRoutes = []
  if results and results.length
    for r in results
      if r.compliant is "yes"
        compliantRoutes.push(r.route)
  # list the cards to display
  is_compliant = false
  cards = []
  if funder_config
    if funder_config.cards? and funder_config.cards.length
      for cardConfig in funder_config.cards
        if _matches(cardConfig, compliantRoutes)
          cards.push(cardConfig)
          if cardConfig.compliant is true
            is_compliant = true

  # sort the cards according to the correct order
  sorted_cards = []
  if cards
    if funder_config.card_order? and funder_config.card_order.length
      for next_card in funder_config.card_order
        for card in cards
          if card.id is next_card
            sorted_cards.push(card)
    else
      sorted_cards = cards

  return [sorted_cards, is_compliant]
