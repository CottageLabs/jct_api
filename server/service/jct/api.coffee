import moment from 'moment'
import mailgun from 'mailgun-js'
import fs from 'fs'
import tar from 'tar'
import Future from 'fibers/future'
import { Random } from 'meteor/random'
import unidecode from 'unidecode'
import csvtojson from 'csvtojson'
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
@jct_institution = new API.collection {index:"jct", type:"institution", devislive: true}
jct_journal = new API.collection {index:"jct", type:"journal"}
jct_agreement = new API.collection {index:"jct", type:"agreement"}
jct_compliance = new API.collection {index:"jct", type:"compliance"}
jct_unknown = new API.collection {index:"jct", type:"unknown"}


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
          ret.push issn: r.issn, ror: r.ror, id: log[0].result.split(' - ')[1]
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


API.service.jct.calculate = (params={}, refresh, checks=['sa', 'doaj', 'ta', 'tj'], retention=true, sa_prohibition=true) ->
  # given funder(s), journal(s), institution(s), find out if compliant or not
  # note could be given lists of each - if so, calculate all and return a list
  if params.issn
    params.journal = params.issn
    delete params.issn
  if params.ror
    params.institution = params.ror
    delete params.ror
  refresh ?= params.refresh if params.refresh?
  if params.checks?
    checks = if typeof params.checks is 'string' then params.checks.split(',') else params.checks
  retention = params.retention if params.retention?

  res =
    request:
      started: Date.now()
      ended: undefined
      took: undefined
      journal: []
      funder: []
      institution: []
      checks: checks
      retention: retention
    compliant: false
    cache: true
    results: []

  return res if not params.journal

  issnsets = {}
  
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

  rq = Random.id() # random ID to store with the cached results, to measure number of unique requests that aggregate multiple sets of entities
  checked = 0
  _check = (funder, journal, institution) ->
    hascompliant = false
    allcached = true
    _results = []
    cr = sa: ('sa' in checks), doaj: ('doaj' in checks), ta: ('ta' in checks), tj: ('tj' in checks)

    _ck = (which) ->
      allcached = false
      Meteor.setTimeout () ->
        if which is 'sa'
          rs = API.service.jct.sa (issnsets[journal] ? journal), (if institution? then institution else undefined), funder, retention, sa_prohibition
        else
          rs = API.service.jct[which] (issnsets[journal] ? journal), (if institution? and which is 'ta' then institution else undefined)
        if rs
          for r in (if _.isArray(rs) then rs else [rs])
            hascompliant = true if r.compliant is 'yes'
            if r.compliant is 'unknown'
              API.service.jct.unknown r, funder, journal, institution
            _results.push r
        cr[which] = Date.now()
      , 1
    for c in checks
      _ck(c) if cr[c]

    while cr.sa is true or cr.doaj is true or cr.ta is true or cr.tj is true
      future = new Future()
      Meteor.setTimeout (() -> future.return()), 100
      future.wait()
    res.compliant = true if hascompliant
    delete res.cache if not allcached
    # store a new set of results every time without removing old ones, to keep track of incoming request amounts
    jct_compliance.insert journal: journal, funder: funder, institution: institution, retention: retention, rq: rq, checks: checks, compliant: hascompliant, cache: allcached, results: _results
    res.results.push(rs) for rs in _results

    checked += 1

  combos = [] # make a list of all possible valid combos of params
  for j in (if params.journal and params.journal.length then params.journal else [undefined])
    cm = journal: j
    for f in (if params.funder and params.funder.length then params.funder else [undefined]) # does funder have any effect? - probably not right now, so the check will treat them the same
      cm = _.clone cm
      cm.funder = f
      for i in (if params.institution and params.institution.length then params.institution else [undefined])
        cm = _.clone cm
        cm.institution = i
        combos.push cm

  console.log 'Calculating for:'
  console.log combos

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


API.service.jct.permission = (issn, institution) ->
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
    permsurl = 'https://api.openaccessbutton.org/permissions?meta=false&issn=' + (if typeof issn is 'string' then issn else issn.join(',')) + (if typeof institution is 'string' then '&ror=' + institution else if institution? and Array.isArray(institution) and institution.length then '&ror=' + institution.join(',') else '')
    perms = HTTP.call('GET', permsurl, {timeout:3000}).data
    if perms.best_permission?
      res.compliant = 'no' # set to no until a successful route through is found
      pb = perms.best_permission
      res.log.push code: 'SA.InOAB'
      lc = false
      pbls = [] # have to do these now even if can't archive, because needed for new API code algo values
      possibleLicences = pb.licences ? []
      if pb.licence
        possibleLicences.push({type: pb.licence})
      for l in possibleLicences
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
            else if not possibleLicences or possibleLicences.length is 0
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


# Calculate self archiving check. It combines, sa_prohibited, OA.works permission and rr checks
API.service.jct.sa = (journal, institution, funder, retention=true, sa_prohibition=true) ->
  # Get SA prohibition
  if journal and sa_prohibition
    res_sa = API.service.jct.sa_prohibited journal, undefined
    if res_sa and res_sa.compliant is 'no'
      return res_sa

  # Get OA.Works permission
  rs = API.service.jct.permission journal, institution

  # merge the qualifications and logs from SA prohibition into OA.Works permission
  rs.qualifications ?= []
  if res_sa?.qualifications? and res_sa.qualifications.length
    for q in (if _.isArray(res_sa.qualifications) then res_sa.qualifications else [res_sa.qualifications])
      rs.qualifications.push(q)
  rs.log ?= []
  if res_sa?.log? and res_sa.log.length
    for l in (if _.isArray(res_sa.log) then res_sa.log else [res_sa.log])
      rs.log.push(l)

  # check for retention
  if rs
    _rtn = {}
    for r in (if _.isArray(rs) then rs else [rs])
      if r.compliant isnt 'yes' and retention
        # only check retention if the funder allows it - and only if there IS a funder
        # funder allows if their rights retention date
        if journal and funder? and fndr = API.service.jct.funders funder
          r.funder = funder
          # 1609459200000 = Wed Sep 25 52971
          # if fndr.retentionAt? and (fndr.retentionAt is 1609459200000 or fndr.retentionAt >= Date.now())
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


API.service.jct.doaj = (issn) ->
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
    while (total is 0 or counter < total) and error_count < 11
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
    console.log 'Setting up a daily import check which will run an import if it is a Saturday'
    # if later updates are made to run this on a cluster again, make sure that only one server runs this (e.g. use the import setting above where necessary)
    Meteor.setInterval () ->
      today = new Date()
      if today.getDay() is 6 # if today is a Saturday run an import
        console.log 'Starting Saturday import'
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
      for un in jct_unknown.fetch q, {newest: false}
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
  # A series of queries based on journals, with existing knowledge of their policies. 
  # To test TJ and Rights retention elements of the algorithm some made up information is included, 
  # this is marked with [1]. Not all queries test all the compliance routes (in particular rights retention).
  # Expected JCT Outcome, is what the outcome should be based on reading the information within journal, institution and funder data. 
  # Actual JCT Outcome is what was obtained by walking through the algorithm under the assumption that 
  # the publicly available information is within the JCT data sources.
  params.refresh = true
  params.sa_prohibition = true if not params.sa_prohibition?
  params.test = params.tests if params.tests?
  params.test = params.test.toString() if typeof params.test is 'number'
  if typeof params.test is 'string'
    ns = 1: 'one', 2: 'two', 3: 'three', 4: 'four', 5: 'five', 6: 'six', 7: 'seven', 8: 'eight', 9: 'nine', 10: 'ten'
    for n in ['10','1','2','3','4','5','6','7','8','9']
      params.test = params.test.replace n, ns[n]
    params.test = params.test.split ','
  
  res = pass: true, fails: [], results: []

  queries =
    one: # Query 1
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc TA)
      institution: 'Cardiff University' # (subscriber to Jisc TA) 03kk7td41
      funder: 'Wellcome'
      'expected outcome': 'Researcher can publish via gold open access route or via TA'
      qualification: 'Researcher must be corresponding author to be eligible for TA'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and JSON.stringify(r.results).indexOf('corresponding_authors') isnt -1
    two: # Query 2
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc TA)
      institution: 'Emory University' # (no TA or Wiley agreement) 03czfpz43
      funder: 'Wellcome'
      'expected outcome': 'Researcher can publish via gold open access route'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and JSON.stringify(r.results).split('"fully_oa"')[1].split('"issn"')[0].indexOf('"yes"') isnt -1
    three: # Query 3
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc & VSNU TAs)
      institution: ['Emory University', 'Cardiff University', 'Utrecht University'] # 03czfpz43,03kk7td41,04pp8hn57 (Emory has no TA or Wiley account, Cardiff is subscriber to Jisc TA, Utrecht is subscriber to VSNU TA  which expires prior to 1 Jan 2021)
      funder: ['Wellcome', 'NWO']
      'expected outcome': 'For Cardiff: Researcher can publish via gold open access route or via TA (Qualification: Researcher must be corresponding author to be eligible for TA). For Emory and Utrecht: Researcher can publish via gold open access route'
      'actual outcome': 'As expected'
      test: (r) -> 
        if r.compliant
          rs = JSON.stringify r.results
          if rs.indexOf('TA.Exists') isnt -1
            return rs.split('"fully_oa"')[1].split('"issn"')[0].indexOf('"yes"') isnt -1
        return false
    four: # Query 4
      journal: 'Proceedings of the Royal Society B' # (subscription journal published by Royal Society, AAM can be shared CC BY no embargo, UK Jisc Read Publish Deal)
      institution: 'Rothamsted Research' # (subscribe to Read Publish Deal) 0347fy350
      funder: 'European Commission' # EC
      'expected outcome': 'Researcher can self-archive or publish via Read Publish Deal'
      qualification: 'Research must be corresponding author to be eligible for Read Publish Deal'
      'actual outcome': 'As expected'
      test: (r) -> 
        if r.compliant
          rs = JSON.stringify r.results
          return rs.indexOf('corresponding_authors') isnt -1 and rs.indexOf('TA.Exists') isnt -1
        return false
    five: # Query 5
      journal: 'Proceedings of the Royal Society B' # (subscription journal published by Royal Society, AAM can be shared CC BY no embargo, UK Jisc Read Publish Deal)
      institution: 'University of Cape Town' # 03p74gp79
      funder: 'Bill & Melinda Gates Foundation' # Bill & Melinda Gates Foundation billmelindagatesfoundation
      'expected outcome': 'Researcher can self-archive'
      'actual outcome': 'As expected'
      test: (r) -> 
        if r.compliant
          for rs in r.results
            if rs.route is 'self_archiving' and rs.compliant is 'yes'
              return true
        return false
    six: # Query 6
      journal: '1477-9129' # Development (published by Company of Biologists, not the other one, hence done by ISSN) # (Transformative Journal, AAM 12 month embargo) 0951-1991
      institution: 'University of Cape Town' # 03p74gp79
      funder: 'SAMRC'
      'expected outcome': 'Researcher can publish via payment of APC (Transformative Journal)'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and JSON.stringify(r.results).indexOf('TJ.Exists') isnt -1
    seven: # Query 7
      journal: 'Brill Research Perspectives in Law and Religion' # (Subscription Journal, VSNU Read Publish Agreement, AAM can be shared CC BY-NC no embargo)
      institution: 'University of Amsterdam' # 04dkp9463
      funder: 'NWO'
      'expected outcome': 'Research can publish via the Transformative Agreement'
      qualification: 'Researcher must be corresponding author to take advantage of the TA.'
      'actual outcome': 'As expected'
      test: (r) ->
        if r.compliant
          rs = JSON.stringify r.results
          return rs.indexOf('corresponding_authors') isnt -1 and rs.indexOf('TA.Exists') isnt -1
        return false
    eight: # Query 8
      journal: 'Migration and Society' # (Subscribe to Open, CC BY, CC BY-ND and CC BY-NC-ND licences available but currently only CC BY-NC-ND in DOAJ)
      institution: 'University of Vienna' # 03prydq77
      funder: 'FWF'
      'expected outcome': 'No routes to compliance'
      'actual outcome': 'As expected' # this is not possible because everything is currently compliant due to rights retention
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).indexOf('SA.Compliant') isnt -1
    nine: # Query 9 
      journal: 'Folia Historica Cracoviensia' # (fully oa, in DOAJ, CC BY-NC-ND)
      institution: ['University of Warsaw', 'University of Ljubljana'] # 039bjqg32,05njb9z20
      funder: ['NCN']
      'expected outcome': 'No route to compliance.' # this is impossible due to rights retention
      'actual outcome': 'As expected'
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).indexOf('SA.Compliant') isnt -1
    ten: # Query 10
      journal: 'Journal of Clinical Investigation' # (subscription for front end material, research articles: publication fee, no embargo, CC BY licence where required by funders, not in DOAJ, Option 5 Rights Retention Policy [1])
      institution: 'University of Vienna' # 03prydq77
      funder: 'FWF'
      'expected outcome': 'Researcher can publish via standard publication route'
      'actual outcome': 'Researcher cannot publish in this journal and comply with funders OA policy' # as there is no rights retention this is impossible so it does succeed
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).indexOf('SA.Compliant') isnt -1

  for q of queries
    if not params.test? or q in params.test
      qr = queries[q]
      ans = query: q
      ans.pass = false
      ans.inputs = queries[q]
      ans.discovered = issn: [], funder: [], ror: []
      for k in ['journal','institution','funder']
        for j in (if typeof qr[k] is 'string' then [qr[k]] else qr[k])
          try
            ans.discovered[if k is 'journal' then 'issn' else if k is 'institution' then 'ror' else 'funder'].push API.service.jct.suggest[k](j).data[0].id
          catch
            console.log k, j
      ans.result = API.service.jct.calculate {funder: ans.discovered.funder, issn: ans.discovered.issn, ror: ans.discovered.ror}, params.refresh, params.checks, params.retention, params.sa_prohibition
      ans.pass = queries[q].test ans.result
      if ans.pass isnt true
        res.pass = false
        res.fails.push q
      res.results.push ans
  
  delete res.fails if not res.fails.length
  return res


