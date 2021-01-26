
import moment from 'moment'
import Future from 'fibers/future'
import { Random } from 'meteor/random'
import unidecode from 'unidecode'

'''
The JCT API is a plugin for the noddy API stack. This API defines 
the routes needed to support the JCT UIs, and the admin feed-ins from sheets, and 
collates source data from DOAJ and OAB systems, as well as other services run within 
the leviathan noddy API stack (such as the academic search capabilities it already had).

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

# define the necessary collections
jct_agreement = new API.collection {index:"jct",type:"agreement"}
jct_compliance = new API.collection {index:"jct",type:"compliance"}
jct_unknown = new API.collection {index:"jct",type:"unknown"}

# define endpoints that the JCT requires (to be served at a dedicated domain)
API.add 'service/jct', get: () -> return 'cOAlition S Journal Checker Tool. Service provided by Cottage Labs LLP. Contact us@cottagelabs.com'

API.add 'service/jct/calculate', get: () -> return API.service.jct.calculate this.queryParams

API.add 'service/jct/suggest', get: () -> return API.service.jct.suggest this.queryParams.which, this.queryParams.q, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which', get: () -> return API.service.jct.suggest this.urlParams.which, undefined, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which/:ac', get: () -> return API.service.jct.suggest this.urlParams.which, this.urlParams.ac, this.queryParams.from, this.queryParams.size

API.add 'service/jct/ta', 
  get: () -> 
    if this.queryParams.issn or this.queryParams.journal
      # should this find all possible matching ISSNs?
      res = API.service.jct.ta this.queryParams.issn ? this.queryParams.journal, this.queryParams.institution ? this.queryParams.ror
      ret = []
      for r in (if not _.isArray(res) then [res] else res)
        if r.compliant is 'yes'
          ret.push issn: r.issn, ror: r.ror, id: log[0].result.split(' - ')[1]
      return if ret.length then ret else 404
    else
      return jct_agreement.search this.queryParams

API.add 'service/jct/tj', get: () -> return API.service.jct.tj this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/tj/:issn', 
  get: () -> 
    res = API.service.jct.tj this.urlParams.issn , this.queryParams.refresh
    return if res?.compliant isnt 'yes' then 404 else issn: this.urlParams.issn, transformative_journal: true

API.add 'service/jct/funder', get: () -> return API.service.jct.funders undefined, this.queryParams.refresh
API.add 'service/jct/funder/:iid', get: () -> return API.service.jct.funders this.urlParams.iid

API.add 'service/jct/feedback',
  get: () -> return API.service.jct.feedback this.queryParams
  post: () -> return API.service.jct.feedback this.bodyParams

# and some administrative ones
API.add 'service/jct/import', 
  get: 
    roleRequired: if API.settings.dev then undefined else 'jct.admin'
    action: () -> 
      Meteor.setTimeout (() => API.service.jct.import this.queryParams), 1
      return true

API.add 'service/jct/unknown', get: () -> return jct_unknown.search this.queryParams
API.add 'service/jct/unknown/:start/:end', 
  get: () -> 
    # TODO convert this to return a csv if URL ends with .csv, not using the old built-in method to do that
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
    return res

API.add 'service/jct/compliance', get: () -> return jct_compliance.search this.queryParams
API.add 'service/jct/compliant', () -> return API.service.jct.compliance this.queryParams.funder, this.queryParams.journal, this.queryParams.institution, this.queryParams.retention, this.queryParams.checks, this.queryParams.refresh, this.queryParams.noncompliant ? false

API.add 'service/jct/test', get: () -> return API.service.jct.test this.queryParams



_jct_clean = (str) ->
  pure = /[!-/:-@[-`{-~¡-©«-¬®-±´¶-¸»¿×÷˂-˅˒-˟˥-˫˭˯-˿͵;΄-΅·϶҂՚-՟։-֊־׀׃׆׳-״؆-؏؛؞-؟٪-٭۔۩۽-۾܀-܍߶-߹।-॥॰৲-৳৺૱୰௳-௺౿ೱ-ೲ൹෴฿๏๚-๛༁-༗༚-༟༴༶༸༺-༽྅྾-࿅࿇-࿌࿎-࿔၊-၏႞-႟჻፠-፨᎐-᎙᙭-᙮᚛-᚜᛫-᛭᜵-᜶។-៖៘-៛᠀-᠊᥀᥄-᥅᧞-᧿᨞-᨟᭚-᭪᭴-᭼᰻-᰿᱾-᱿᾽᾿-῁῍-῏῝-῟῭-`´-῾\u2000-\u206e⁺-⁾₊-₎₠-₵℀-℁℃-℆℈-℉℔№-℘℞-℣℥℧℩℮℺-℻⅀-⅄⅊-⅍⅏←-⏧␀-␦⑀-⑊⒜-ⓩ─-⚝⚠-⚼⛀-⛃✁-✄✆-✉✌-✧✩-❋❍❏-❒❖❘-❞❡-❵➔➘-➯➱-➾⟀-⟊⟌⟐-⭌⭐-⭔⳥-⳪⳹-⳼⳾-⳿⸀-\u2e7e⺀-⺙⺛-⻳⼀-⿕⿰-⿻\u3000-〿゛-゜゠・㆐-㆑㆖-㆟㇀-㇣㈀-㈞㈪-㉃㉐㉠-㉿㊊-㊰㋀-㋾㌀-㏿䷀-䷿꒐-꓆꘍-꘏꙳꙾꜀-꜖꜠-꜡꞉-꞊꠨-꠫꡴-꡷꣎-꣏꤮-꤯꥟꩜-꩟﬩﴾-﴿﷼-﷽︐-︙︰-﹒﹔-﹦﹨-﹫！-／：-＠［-｀｛-･￠-￦￨-￮￼-�]|\ud800[\udd00-\udd02\udd37-\udd3f\udd79-\udd89\udd90-\udd9b\uddd0-\uddfc\udf9f\udfd0]|\ud802[\udd1f\udd3f\ude50-\ude58]|\ud809[\udc00-\udc7e]|\ud834[\udc00-\udcf5\udd00-\udd26\udd29-\udd64\udd6a-\udd6c\udd83-\udd84\udd8c-\udda9\uddae-\udddd\ude00-\ude41\ude45\udf00-\udf56]|\ud835[\udec1\udedb\udefb\udf15\udf35\udf4f\udf6f\udf89\udfa9\udfc3]|\ud83c[\udc00-\udc2b\udc30-\udc93]/g;
  str = str.replace(pure, ' ')
  return str.toLowerCase().replace(/ +/g,' ').trim()

# and now define the methods
API.service ?= {}
API.service.jct = {}
API.service.jct.suggest = (which='journal', str, from, size=100) ->
  # Journals and institutions are suggested out of the TAs we have, then fall back to the academic journal/institution catalogue.
  # We don't insert to the catalogue when we load the TAs then do an easier aggregate search, because there was problems with data quality.
  if which is 'funder'
    res = []
    for f in API.service.jct.funders()
      matches = true
      if str isnt f.id
        for s in (if str then str.toLowerCase().split(' ') else [])
          if s not in ['of','the','and'] and f.funder.toLowerCase().indexOf(s) is -1
            matches = false
      res.push({title: f.funder, id: f.id}) if matches
    return total: res.length, data: res
  else if which is 'institution'
    ret = total: 0, data: []
    try ret = API.service.academic.institution.suggest str, from, size
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
  else
    ret = total: 0, data: []
    ret = API.service.academic.journal.suggest str, from, size
    if ret.data.length < 10
      seen = []
      for re in ret.data
        seen.push(ir) for ir in re.issn
      q = {query: {filtered: {query: {query_string: {query: 'issn.exact:*'}}, filter: {bool: {should: []}}}}, size: size}
      q.from = from if from?
      if str
        if str.indexOf(' ') is -1
          if str.indexOf('-') isnt -1 and str.length is 9
            q.query.filtered.query.query_string.query = 'issn.exact:"' + str + '"'
          else
            if str.indexOf('-') isnt -1
              q.query.filtered.query.query_string.query = '(issn:"' + str.replace('-','" AND issn:') + '*)'
            else
              q.query.filtered.query.query_string.query = 'issn:' + str + '*'
            q.query.filtered.query.query_string.query += ' OR journal:"' + str + '" OR journal:' + str + '* OR journal:' + str + '~'
        else
          str = _jct_clean str
          q.query.filtered.query.query_string.query = 'issn:* AND (journal:"' + str + '" OR '
          q.query.filtered.query.query_string.query += (if str.indexOf(' ') is -1 then 'journal:' + str + '*' else '(journal:' + str.replace(/ /g,'~ AND journal:') + '*)') + ')'
      res = jct_agreement.search q
      if res?.hits?.total
        ret.total += res.hits.total
        starts = []
        extra = []
        for rec in res?.hits?.hits ? []
          allowed = true
          for isn in rec._source.issn
            allowed = false if isn in seen
          if allowed
            if not str or JSON.stringify(rec._source.issn).indexOf(str) isnt -1 or _jct_clean(rec._source.journal).startsWith(str)
              starts.push title: rec._source.journal, id: rec._source.issn[0], issn: rec._source.issn, ta: true
            else
              extra.push title: rec._source.journal, id: rec._source.issn[0], issn: rec._source.issn, ta: true
        ret.data = _.union ret.data, _.union starts.sort((a, b) -> return a.title.length - b.title.length), extra.sort((a, b) -> return a.title.length - b.title.length)
    return ret

API.service.jct.issns = (issn) -> # from one or more ISSNs, check for and return all ISSNs that are for the same item
  issn = issn.split(',') if typeof issn is 'string'
  seen = []
  for i in issn
    if i not in seen and af = API.service.jct.suggest undefined, i
      seen.push i
      if af.data?length
        for an in af.data[0].issn ? []
          seen.push i
          issn.push(an) if an not in issn
  return issn


API.service.jct.calculate = (params={}, refresh, checks=['permission', 'doaj', 'ta', 'tj'], retention=true) ->
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
    params[p] = params[p].split(',') if typeof params[p] is 'string' and params[p].indexOf(',') isnt -1
    if typeof params[p] is 'string' and (params[p].indexOf(' ') isnt -1 or (p is 'journal' and params[p].indexOf('-') is -1))
      sg = API.service.jct.suggest p, params[p]
      if sg.data and sg.data.length
        ad = sg.data[0]
        params[p] = ad.id
        res.request[p].push {id: params[p], title: ad.title, issn: ad.issn, publisher: ad.publisher}
        issnsets[params[p]] = ad.issn if p is 'journal' and _.isArray(ad.issn) and ad.issn.length
    params[p] = [params[p]] if typeof params[p] is 'string'
    params[p] ?= []
    if not res.request[p].length
      for v in params[p]
        if sg = API.service.jct.suggest p, v
          if sg.data and sg.data.length
            ad = sg.data[0]
            res.request[p].push {id: ad.id, title: ad.title, issn: ad.issn, publisher: ad.publisher}
            issnsets[v] ?= ad.issn if p is 'journal' and _.isArray(ad.issn) and ad.issn.length
        res.request[p].push({id: params[p][v]}) if not sg?.data

  rq = Random.id() # random ID to store with the cached results, to measure number of unique requests that aggregate multiple sets of entities
  checked = 0
  _check = (funder, journal, institution) ->
    hascompliant = false
    allcached = true
    _results = []
    cr = permission: ('permission' in checks), doaj: ('doaj' in checks), ta: ('ta' in checks), tj: ('tj' in checks)

    # look for cached results for the same values in jct_compliance - if found, use them, and don't recheck permission types already found there
    if false # disable use of pre-calculated compliance
      for pr in pre = API.service.jct.compliance funder, journal, institution, retention, checks, refresh
        hascompliant = true if pr.compliant is 'yes'
        cr[if pr.route is 'fully_oa' then 'doaj' else if pr.route is 'self_archiving' then 'permission' else pr.route] = false
        _results.push pr

    _rtn = {}
    _ck = (which) ->
      allcached = false
      Meteor.setTimeout () ->
        #try
        if rs = API.service.jct[which] (issnsets[journal] ? journal), (if institution? and which in ['permission','ta'] then institution else undefined)
          for r in (if _.isArray(rs) then rs else [rs])
            hascompliant = true if r.compliant is 'yes'
            if which is 'permission' and r.compliant isnt 'yes' and retention
              # new change: only check retention if the funder allows it - and only if there IS a funder
              # funder allows if their rights retention date 
              if funder? and fndr = API.service.jct.funders funder
                r.funder = funder
                if fndr.retentionAt? and (fndr.retentionAt is 1609459200000 or fndr.retentionAt >= Date.now())
                  # retention is a special case on permissions, done this way so can be easily disabled for testing
                  _rtn[journal] ?= API.service.jct.retention journal
                  r.compliant = _rtn[journal].compliant
                  hascompliant = true if r.compliant is 'yes'
                  r.log.push(lg) for lg in _rtn[journal].log
                  if _rtn[journal].qualifications? and _rtn[journal].qualifications.length
                    r.qualifications ?= []
                    r.qualifications.push(ql) for ql in _rtn[journal].qualifications
            if r.compliant is 'unknown'
              API.service.jct.unknown r, funder, journal, institution
            _results.push r
        cr[which] = Date.now()
        #catch
        #  cr[which] = false
      , 1
    for c in checks
      _ck(c) if cr[c]

    while cr.permission is true or cr.doaj is true or cr.ta is true or cr.tj is true
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


# check to see if we already know if a given set of entities is compliant
# and if so, check if that compliance is still valid now
API.service.jct.compliance = (funder, journal, institution, retention, checks=['permission', 'doaj', 'ta', 'tj'], refresh=86400000, noncompliant=true) ->
  checks = checks.split(',') if typeof checks is 'string'
  results = []
  return results if refresh is true or refresh is 0 or not journal
  qr = if journal then 'journal.exact:"' + journal + '"' else ''
  if institution
    qr += ' OR ' if qr isnt ''
    qr += 'institution.exact:"' + institution + '"'
  # For now, since retention checks can't return anything anyway, there's no point searching by funder
  # so this could be disabled... won't do it yet, but keep here as a possibility, and see below loop over results
  if funder
    qr += ' OR ' if qr isnt ''
    qr += 'funder.exact:"' + funder + '"'
  if qr isnt ''
    qr = '(' + qr + ')' if qr.indexOf(' OR ') isnt -1
    qr += ' AND retention:' + retention if retention?
    qr += ' AND compliant:true' if noncompliant isnt true
    qr += ' AND NOT cache:true'
    if refresh isnt false
      qr += ' AND createdAt:>' + (Date.now() - (if typeof refresh is 'number' then refresh else 0))
    # get the most recent calculated compliance for this set of entities
    if pre = jct_compliance.find qr, true
      if pre?.results? and pre.results.length
        for pr in pre.results
          if (pr.route in ['tj','fully_oa'] and journal? and pr.issn? and journal in pr.issn) or (pr.route is 'ta'and journal? and pr.issn? and journal in pr.issn and pr.ror is institution) or (pr.route is 'self_archiving' and journal? and pr.issn? and journal in pr.issn) #and pr.ror is institution and pr.funder is funder)
            # for now, since retention checks can't return anything, just set whatever would have been the default
            # and since OAB runs nearby, can check to see if it holds any records for a given institution, and if not, can re-use a result that didn't rely on one either
            allowed = pr.route isnt 'self_archiving'
            if pr.route is 'self_archiving'
              if institution is pr.ror or (not pr.requiresaffiliation and (not institution or not oab_permissions.find('issuer.id.exact:"' + institution + '"')))
                allowed = true
              if allowed
                pr.qualifications = []
                if funder? and fr = API.service.jct.funders funder
                  if retention
                    pr.qualifications = [{rights_retention_author_advice: ''}]
                    pr.log ?= []
                    if pr.log.length is 0 or pr.log[pr.log.length-1].action isnt 'Check for author rights retention'
                      pr.log.push {action: 'Check for author rights retention', result: 'Rights retention not found, so default compliant'}
                else
                  pr.log.pop() if pr.log? and pr.log.length and pr.log[pr.log.length-1].action is 'Check for author rights retention'
            if allowed
              results.push pr
  return results


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
    log: [{action: 'Check transformative agreements for currently active agreement containing journal and institution'}]
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
        rs.log[0].result = 'A currently active transformative agreement containing "' + journals[j].journal + '" and "' + institutions[j].institution + '" was found - ' + institutions[j].rid
        tas.push rs
  if tas.length is 0
    res.compliant = 'no'
    res.log[0].result = 'There are no current transformative agreements containing the journal and institution'
    tas.push res
  return if tas.length is 1 then tas[0] else tas

# import transformative agreements data from sheets 
# https://github.com/antleaf/jct-project/blob/master/ta/public_data.md
# only validated agreements will be exposed at the following sheet
# https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=1130349201&single=true&output=csv
# get the "Data URL" - if it's a valid URL, and the End Date is after current date, get the csv from it
API.service.jct.ta.import = (mail=true) ->
  try API.service.jct.ta.esac undefined, true
  bads = []
  records = []
  res = sheets: 0, ready: 0, records: 0
  console.log 'starting ta import'
  for ov in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=1130349201&single=true&output=csv'
    console.log ov
    console.log 'imported main sheet'
    res.sheets += 1
    if typeof ov?['Data URL'] is 'string' and ov['Data URL'].trim().indexOf('http') is 0 and ov?['End Date']? and moment(ov['End Date'].trim(), 'YYYY-MM-DD').valueOf() > Date.now()
      res.ready += 1
      src = ov['Data URL'].trim()
      console.log res
      console.log src
      for rec in API.convert.csv2json src
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
          for ik in ['ISSN (Print)','ISSN (Online)']
            for isp in (if typeof rec[ik] is 'string' then rec[ik].split(',') else [])
              if not rec[ik]? or typeof rec[ik] isnt 'string' or rec[ik].indexOf('-') is -1 or rec[ik].split('-').length > 2 or rec[ik].length < 5
                bads.push issn: rec[ik], esac: rec['ESAC ID'], rid: rec.rid, src: src
              isp = isp.toUpperCase().trim()
              rec.issn.push(isp) if isp.length and isp not in rec.issn
          rec.journal = rec['Journal Name'].trim() if rec['Journal Name']?
          rec.corresponding_authors = true if rec['C/A Only'].trim().toLowerCase() is 'yes'
          res.records += 1
          if rec.journal and rec.issn.length
            rec.issn = API.service.jct.issns rec.issn
            records.push rec
  if records.length
    console.log 'Removing and reloading ' + records.length + ' agreements'
    jct_agreement.remove '*'
    jct_agreement.insert records
    res.extracted = records.length
  if mail
    API.mail.send
      from: 'nobody@cottagelabs.com'
      to:  'jct@cottagelabs.zendesk.com' #'jct@cottagelabs.com'
      subject: 'JCT TA import complete' + (if API.settings.dev then ' (dev)' else '')
      text: JSON.stringify res, '', 2
  if bads.length
    API.mail.send
      from: 'nobody@cottagelabs.com'
      to:  'jct@cottagelabs.zendesk.com' #'jct@cottagelabs.com'
      subject: 'JCT TA import found ' + bads.length + ' bad ISSNs' + (if API.settings.dev then ' (dev)' else '')
      text: JSON.stringify bads, '', 2
  return res


# import transformative journals data, which should indicate if the journal IS 
# transformative or just in the list for tracking (to be transformative means to 
# have submitted to the list with the appropriate responses)
# fields called pissn and eissn will contain ISSNs to check against
# check if an issn is in the transformative journals list (to be provided by plan S)
API.service.jct.tj = (issn, refresh=86400000) -> # refresh each day?
  issn = issn.split(',') if typeof issn is 'string'
  # this will be developed further once it is decided where the data will come from
  tjs = []
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'jct', 'tj', undefined, refresh
    tjs = cached
  else
    try
      for rec in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vT2SPOjVU4CKhP7FHOgaf0aRsjSOt-ApwLOy44swojTDFsWlZAIZViC0gdbmxJaEWxdJSnUmNoAnoo9/pub?gid=0&single=true&output=csv'
        tj = {}
        try tj.title = rec['Journal Title'].trim() if rec['Journal Title']
        try
          tj.issn ?= []
          tj.issn.push rec['ISSN (Print)'].trim() if rec['ISSN (Print)']
        try
          tj.issn ?= []
          tj.issn.push rec['e-ISSN (Online/Web)'].trim() if rec['e-ISSN (Online/Web)']
        if tj.issn
          tj.issn = API.service.jct.issns tj.issn
          tjs.push tj
      API.http.cache 'jct', 'tj', tjs

  if issn
    res = 
      route: 'tj'
      compliant: 'unknown'
      qualifications: undefined
      issn: issn
      log: [{action: 'Check transformative journals list for journal'}]

    for t in tjs
      if res.compliant is 'yes'
        break
      for isn in t.issn
        if isn in issn
          res.compliant = 'yes'
          res.log[0].result = 'Journal found in transformative journals list'
          break
    if res.compliant is 'unknown'
      res.compliant = 'no'
      res.log[0].result = 'Journal is not in transformative journals list'
    return res
  else
    return tjs


# what are these qualifications relevant to? TAs?
# there is no funder qualification done now, due to retention policy change decision at ened of October 2020. May be added again later.
# rights_retention_author_advice - 
# rights_retention_funder_implementation - the journal does not have an SA policy and the funder has a rights retention policy that starts in the future. There should be one record of this per funder that meets the conditions, and the following qualification specific data is requried:
# funder: <funder name>
# date: <date policy comes into force (YYYY-MM-DD)
API.service.jct.retention = (issn, refresh) ->
  # check the rights retention data source once it exists if the record is not in OAB
  # for now this is not used directly, just a fallback to something that is not in OAB
  # will be a list of journals by ISSN and a number 1,2,3,4,5
  # import them if not yet present (and probably do some caching)
  rets = []
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'jct', 'retention', undefined, refresh
    rets = cached
  else
    try
      for rt in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTVZwZtdYSUFfKVRGO3jumQcLEjtnbdbw7yJ4LvfC2noYn3IwuTDjA9CEjzSaZjX8QVkWijqa3rmicY/pub?gid=0&single=true&output=csv'
        rt.journal = rt['Journal Name'].trim() if typeof rt['Journal Name'] is 'string'
        rt.issn = []
        rt.issn.push(rt['ISSN (print)'].trim()) if typeof rt['ISSN (print)'] is 'string' and rt['ISSN (print)'].length
        rt.issn.push(rt['ISSN (online)'].trim()) if typeof rt['ISSN (online)'] is 'string'and rt['ISSN (online)'].length
        rt.issn = API.service.jct.issns rt.issn
        rt.position = if typeof rt.Position is 'number' then rt.Position else parseInt rt.Position.trim()
        rt.publisher = rt.Publisher.trim() if typeof rt.Publisher is 'string'
        rets.push(rt) if rt.issn.length and rt.position? and typeof rt.position is 'number' and rt.position isnt null and not isNaN rt.position
      API.http.cache 'jct', 'retention', rets

  if issn
    res =
      route: 'retention' # this is actually only used as a subset of OAB permission self_archiving so far
      compliant: 'yes' # if not present then compliant but with author and funder quals - so what are the default funder quals?
      qualifications: [{'rights_retention_author_advice': ''}]
      issn: issn
      log: [{action: 'Check for author rights retention', result: 'Rights retention not found, so default compliant'}]
    found = false
    for ret in rets
      if found
        break
      for isn in issn
        if isn in ret.issn
          if ret.position is 5 # if present and 5, not compliant
            delete res.qualifications
            res.log[0].result = 'Rights retention number ' + ret.position + ' so not compliant'
            res.compliant = 'no'
          else
            res.log[0].result = 'Rights retention number ' + ret.position + ' so compliant' #, but check funder qualifications if any'
            # https://github.com/antleaf/jct-project/issues/215#issuecomment-726761965
            # if present and any other number, or no answer, then compliant with some funder quals - so what funder quals to add?
            # no funder quals now due to change at end of October 2020. May be introduced again later
          found = true
          break
    return res
  else
    return rets


API.service.jct.permission = (issn, institution) ->
  issn = issn.split(',') if typeof issn is 'string'
  res =
    route: 'self_archiving'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    ror: institution
    funder: undefined
    log: [{action: 'Check Open Access Button Permissions for journal'}]

  try
    perms = API.service.oab.permission {issn: issn, ror: institution}, undefined, undefined, undefined, undefined, false
    if perms.best_permission?
      res.compliant = 'no' # set to no until a successful route through is found
      pb = perms.best_permission
      res.log[0].result = 'The journal is found by OAB Permissions'
      res.log.push {action: 'Check if OAB Permissions says the journal allows archiving'}
      if pb.can_archive
        res.log[1].result = 'OAB Permissions confirms the journal allows archiving'
        res.log.push {action: 'Check if postprint or publisher PDF can be archived'}
        if 'postprint' in pb.versions or 'publisher pdf' in pb.versions or 'acceptedVersion' in pb.versions or 'publishedVersion' in pb.versions
          res.log[2].result = (if 'postprint' in pb.versions or 'acceptedVersion' in pb.versions then 'Postprint' else 'Publisher PDF') + ' can be archived'
          res.log.push {action: 'Check there is no embargo period'}
          # and Embargo is zero
          if typeof pb.embargo_months is 'string'
            try pb.embargo_months = parseInt pb.embargo_months
          if typeof pb.embargo_months isnt 'number' or pb.embargo_months is 0
            res.log[3].result = 'There is no embargo period'
            res.log.push {action: 'Check there is a suitable licence'}
            lc = false
            for l in pb.licences ? []
              if l.type.toLowerCase().replace(/\-/g,'').replace(/ /g,'') in ['ccby','ccbysa','cc0','ccbynd']
                lc = l.type
                break
            if lc
              res.log[4].result = 'There is a suitable ' + lc + ' licence'
              res.compliant = 'yes'
              res.requiresaffiliation = pb.requirements?.author_affiliation_requirement
            else if not pb.licences? or pb.licences.length is 0
              res.log[4].result = 'No licence information was available in OAB permissions'
              res.compliant = 'unknown'
            else
              res.log[4].result = 'No suitable licence found'
          else
            res.log[3].result = 'There is an embargo period of ' + pb.embargo_months + ' months'
        else
          res.log[2].result = 'It is not possible to archive postprint or publisher PDF'
      else
        res.log[1].result = 'OAB Permissions states that the journal does not allow archiving'
    else
      res.log[0].result = 'The journal was not found in OAB Permissions'
  catch
    res.log[0].result = 'The journal was not found in OAB Permissions'

  return res


API.service.jct.doaj = (issn) ->
  issn = issn.split(',') if typeof issn is 'string'
  res =
    route: 'fully_oa'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    log: [{action: 'Check DOAJ applications in case the journal recently applied to be in DOAJ', result: 'Journal does not have an open application to be in DOAJ'}]

  # check if there is an open application for the journal to join DOAJ
  dip = API.use.doaj.journals.inprogress 'pissn.exact:"' + issn.join('" OR pissn.exact:"') + '" OR eissn.exact:"' + issn.join('" OR eissn.exact:"') + '"'
  if dip?.hits?.hits? and dip.hits.hits.length
    pfd = dip.hits.hits[0]._source
    res.log[0].result = 'Journal is awaiting processing for acceptance to join the DOAJ'
    res.log.push {action: 'Check how old the DOAJ application is'}
    if true # if an application, has to have applied within 6 months
      res.log[1].result = 'Application to DOAJ is still current, being less than six months old'
      res.compliant = 'yes'
      res.qualifications = [{doaj_under_review: {}}]
    else
      res.log[1].result = 'Application is more than six months old, so the journal is not a valid route'
      res.compliant = 'no'

  # if there wasn't an application, continue to check DOAJ itself
  if res.compliant is 'unknown'
    res.log.push {action: 'Check if the journal is currently in the DOAJ'}
    if ind = doaj_journal.find 'bibjson.pissn.exact:"' + issn.join('" OR bibjson.pissn.exact:"') + '" OR bibjson.eissn.exact:"' + issn.join('" OR bibjson.eissn.exact:"') + '"'
      res.log[1].result = 'The journal has been found in DOAJ'
      res.log.push action: 'Check if the journal has a suitable licence' # only do licence check for now
      db = ind.bibjson
      # Publishing License	bibjson.license[].type	bibjson.license[].type	CC BY, CC BY SA, CC0	CC BY ND
      pl = false
      if db.license? and db.license.length
        for bl in db.license
          if typeof bl?.type is 'string' and bl.type.toLowerCase().trim().replace(/ /g,'').replace(/-/g,'') in ['ccby','ccbysa','cc0','ccbynd']
            pl = bl.type
            break
      if not db.license?
        res.log[2].result = 'Licence data is missing, compliance cannot be calculated'
      else if pl
        res.log[2].result = 'The journal has a suitable licence: ' + pl
        res.compliant = 'yes'
      else
        res.log[2].result = 'The journal does not have a suitable licence'
        res.compliant = 'no'
    # extra parts used to go here, but have been removed due to algorithm simplification.
    else
      res.log[1].result = 'Journal is not in DOAJ'
      res.compliant = 'no'
  return res


# https://www.coalition-s.org/plan-s-funders-implementation/
API.service.jct.funders = (id,refresh) ->
  res = []
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'jct', 'funders', undefined, refresh
    res = cached
  else
    try
      for r in API.convert.table2json API.http.puppeteer 'https://www.coalition-s.org/plan-s-funders-implementation/'
        rec = 
          funder: r['cOAlition S organisation (funder)']
          launch: r['Launch date for implementing  Plan S-aligned OA policy']
          application: r['Application of Plan S principles ']
          retention: r['Rights Retention Strategy Implementation']
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
        res.push(rec) if rec.id?
      API.http.cache('jct', 'funders', res) if res.length

  if id?
    for e in res
      if e.id is id
        res = e
        break
  return res


API.service.jct.import = (params={}) ->
  # run all imports necessary for up to date data
  res = {}
  res.journals = API.use.doaj.journals.import()
  console.log 'JCT import DOAJ complete'

  res.ta = API.service.jct.ta.import false
  console.log 'JCT import TAs complete'

  res.tj = API.service.jct.tj undefined, true
  res.tj = res.tj.length if _.isArray res.tj
  console.log 'JCT import TJs complete'

  res.retention = API.service.jct.retention undefined, true
  res.retention = res.retention.length if _.isArray res.retention
  console.log 'JCT import retention data complete'

  res.funders = API.service.jct.funders undefined, true
  res.funders = res.funders.length if _.isArray res.funders
  console.log 'JCT import funders complete'

  API.mail.send
    from: 'nobody@cottagelabs.com'
    to:  'jct@cottagelabs.zendesk.com' #'jct@cottagelabs.com'
    subject: 'JCT import complete' + (if API.settings.dev then ' (dev)' else '')
    text: JSON.stringify res, '', 2
  return res

# run import every day on the main machine
_jct_import = () ->
  if API.settings.cluster?.ip? and API.status.ip() not in API.settings.cluster.ip
    Meteor.setInterval (() ->
      newest = jct_agreement.find '*', true
      if newest?.createdAt < Date.now()-86400000
        API.service.jct.import()
      ), 43200000
Meteor.setTimeout _jct_import, 18000


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
    API.mail.send
      from: if params.email.indexOf('@') isnt -1 and params.email.indexOf('.') isnt -1 then params.email else 'nobody@cottagelabs.com'
      to:  'jct@cottagelabs.zendesk.com' #'jct@cottagelabs.com'
      subject: params.subject ? params.feedback.substring(0,100) + if params.feedback.length > 100 then '...' else ''
      text: (if API.settings.dev then '(dev)\n\n' else '') + params.feedback + '\n\n' + (if params.subject then '' else JSON.stringify params, '', 2)
    return true
  else
    return false


API.service.jct.test = (params={}) ->
  # A series of queries based on journals, with existing knowledge of their policies. 
  # To test TJ and Rights retention elements of the algorithm some made up information is included, 
  # this is marked with [1]. Not all queries test all the compliance routes (in particular rights retention).
  # Expected JCT Outcome, is what the outcome should be based on reading the information within journal, institution and funder data. 
  # Actual JCT Outcome is what was obtained by walking through the algorithm under the assumption that 
  # the publicly available information is within the JCT data sources.
  params.refresh = true
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
          rs = JSON.stringify(r.results).toLowerCase()
          if rs.indexOf('currently active transformative agreement containing \\"aging cell\\" and \\"cardiff university\\" was found - wiley2020jisc') isnt -1
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
          rs = JSON.stringify(r.results).toLowerCase()
          return rs.indexOf('corresponding_authors') isnt -1 and rs.indexOf('currently active transformative agreement containing \\"proceedings b\\" and \\"rothamsted research\\" was found - trs2021jisc') isnt -1
        return false
    five: # Query 5
      journal: 'Proceedings of the Royal Society B' # (subscription journal published by Royal Society, AAM can be shared CC BY no embargo, UK Jisc Read Publish Deal)
      institution: 'University of Cape Town' # 03p74gp79
      funder: 'Bill & Melinda Gates Foundation' # Bill & Melinda Gates Foundation billmelindagatesfoundation
      'expected outcome': 'Researcher can self-archive'
      'actual outcome': 'As expected'
      test: (r) -> 
        if r.compliant
          rs = JSON.stringify(r.results).toLowerCase()
          return rs.indexOf('journal is not in transformative journals list') isnt -1 and rs.indexOf('there are no current transformative agreements') isnt -1 and rs.indexOf('journal is not in doaj') isnt -1
        return false
    six: # Query 6
      journal: '1477-9129' # Development (published by Company of Biologists, not the other one, hence done by ISSN) # (Transformative Journal, AAM 12 month embargo) 0951-1991
      institution: 'University of Cape Town' # 03p74gp79
      funder: 'SAMRC'
      'expected outcome': 'Researcher can publish via payment of APC (Transformative Journal)'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and JSON.stringify(r.results).toLowerCase().indexOf('journal found in transformative journals list') isnt -1
    seven: # Query 7
      journal: 'Brill Research Perspectives in Law and Religion' # (Subscription Journal, VSNU Read Publish Agreement, AAM can be shared CC BY-NC no embargo)
      institution: 'University of Amsterdam' # 04dkp9463
      funder: 'NWO'
      'expected outcome': 'Research can publish via the Transformative Agreement'
      qualification: 'Researcher must be corresponding author to take advantage of the TA.'
      'actual outcome': 'As expected'
      test: (r) ->
        if r.compliant
          rs = JSON.stringify(r.results).toLowerCase()
          return rs.indexOf('corresponding_authors') isnt -1 and rs.indexOf('currently active transformative agreement containing') isnt -1 and rs.indexOf('brill research perspectives') isnt -1 and rs.indexOf('law and religion') isnt -1 and rs.indexOf('amsterdam') isnt -1
        return false
    eight: # Query 8
      journal: 'Migration and Society' # (Subscribe to Open, CC BY, CC BY-ND and CC BY-NC-ND licences available but currently only CC BY-NC-ND in DOAJ)
      institution: 'University of Vienna' # 03prydq77
      funder: 'FWF'
      'expected outcome': 'No routes to compliance'
      'actual outcome': 'As expected' # this is not possible because everything is currently compliant due to rights retention
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).toLowerCase('rights retention not found, so default compliant') isnt -1
    nine: # Query 9 
      journal: 'Folia Historica Cracoviensia' # (fully oa, in DOAJ, CC BY-NC-ND)
      institution: ['University of Warsaw', 'University of Ljubljana'] # 039bjqg32,05njb9z20
      funder: ['NCN']
      'expected outcome': 'No route to compliance.' # this is impossible due to rights retention
      'actual outcome': 'As expected'
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).toLowerCase('rights retention not found, so default compliant') isnt -1
    ten: # Query 10
      journal: 'Journal of Clinical Investigation' # (subscription for front end material, research articles: publication fee, no embargo, CC BY licence where required by funders, not in DOAJ, Option 5 Rights Retention Policy [1])
      institution: 'University of Vienna' # 03prydq77
      funder: 'FWF'
      'expected outcome': 'Researcher can publish via standard publication route'
      'actual outcome': 'Researcher cannot publish in this journal and comply with funders OA policy' # as there is no rights retention this is impossible so it does succeed
      #test: (r) -> return not r.compliant
      test: (r) -> return r.compliant and JSON.stringify(r.results).toLowerCase('rights retention not found, so default compliant') isnt -1

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
            ans.discovered[if k is 'journal' then 'issn' else if k is 'institution' then 'ror' else 'funder'].push API.service.jct.suggest(k, j).data[0].id
          catch
            console.log k, j
      ans.result = API.service.jct.calculate {funder: ans.discovered.funder, issn: ans.discovered.issn, ror: ans.discovered.ror}, params.refresh, params.checks, params.retention
      ans.pass = queries[q].test ans.result
      if ans.pass isnt true
        res.pass = false
        res.fails.push q
      res.results.push ans
  
  delete res.fails if not res.fails.length
  return res


