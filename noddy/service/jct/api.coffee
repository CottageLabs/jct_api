
import moment from 'moment'
import Future from 'fibers/future'
import { Random } from 'meteor/random'

'''
The JCT API is a plugin for the leviathanindustries/noddy API stack. This API defines 
the routes needed to support the JCT UIs, and the admin feed-ins from sheets, and 
collates source data from DOAJ and OAB systems, as well as other services run within 
the leviathan noddy API stack (such as the academic search capabilities it already had).

jct project API spec doc:
https://github.com/antleaf/jct-project/blob/master/api/spec.md

algorithm spec docs:
https://docs.google.com/document/d/1-jdDMg7uxJAJd0r1P7MbavjDi1r261clTXAv_CFMwVE/edit?ts=5efb583f
https://docs.google.com/spreadsheets/d/11tR_vXJ7AnS_3m1_OSR3Guuyw7jgwPgh3ETgsIX0ltU/edit#gid=105475641

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

#jct_compliance.remove '*'
#jct_unknown.remove '*'

# define the jct service object in the overall API
API.service ?= {}
API.service.jct = {}



# define all web endpoints that the JCT requires - these are served on the main API, 
# but also will be directly routed from a dedicated domain, so that service/jct/ will 
# be unnecessary from that domain (and it will be routed via cloudlfare for caching too)
API.add 'service/jct', 
  get: 
    () ->
      if _.isEmpty this.queryParams
        return 'cOAlition S Journal Checker Tool. Service provided by Cottage Labs LLP. Contact us@cottagelabs.com'
      else
        return API.service.jct.calculate this.queryParams
  post: () -> return API.service.jct.calculate this.bodyParams

API.add 'service/jct/calculate', 
  get: () -> return API.service.jct.calculate this.queryParams
  post: () -> return API.service.jct.calculate this.bodyParams

API.add 'service/jct/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.import this.queryParams), 1
    return true

# these should also be cached via cloudflare or similar, so that over time we build known lists of suggestions
# (and can preload them by sending requests to these endpoints with a range of starting characters)
API.add 'service/jct/suggest', get: () -> return API.service.jct.suggest this.queryParams.which, this.queryParams.q, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which', get: () -> return API.service.jct.suggest this.urlParams.which, undefined, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which/:ac', get: () -> return API.service.jct.suggest this.urlParams.which, this.urlParams.ac, this.queryParams.from, this.queryParams.size

API.add 'service/jct/unknown', () -> return jct_unknown.search this
API.add 'service/jct/unknown/send', get: () -> return API.service.jct.unknown undefined, undefined, undefined, undefined, this.queryParams.since ? true
API.add 'service/jct/unknown/:start/:end', 
  csv: true
  get: () -> 
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

API.add 'service/jct/compliance', () -> return jct_compliance.search this
API.add 'service/jct/compliant', () -> return API.service.jct.compliance this.queryParams.funder, this.queryParams.journal, this.queryParams.institution, this.queryParams.retention, this.queryParams.checks, this.queryParams.refresh, this.queryParams.noncompliant ? false

API.add 'service/jct/journal', () -> return academic_journal.search this # should journals be restricted to only those of the 200 publishers plan S wish to focus on?

API.add 'service/jct/funder', 
  csv: true
  get: () -> return API.service.jct.funders undefined, this.queryParams.refresh
API.add 'service/jct/funders', 
  csv: true
  get: () -> return API.service.jct.funders undefined, this.queryParams.refresh

API.add 'service/jct/institution', get: () -> return [] # return a total list of all the institutions we know? Any more use than the suggest route?
API.add 'service/jct/institutions', get: () -> return [] # return a total list of all the institutions we know? Any more use than the suggest route?

API.add 'service/jct/publisher', 
  csv: true
  get: () -> return API.service.jct._publishers
API.add 'service/jct/publishers', 
  csv: true
  get: () -> return API.service.jct._publishers
#API.add 'service/jct/publisher/:pid/journals', get: () -> return [] # list all journals we know of for a given publisher name or ID?

API.add 'service/jct/journal/:iid', 
  get: () ->
    if j = academic_journal.get this.urlParams.iid
      return j
    else if j = academic_journal.find issn: this.urlParams.iid
      return j
    else
      return undefined

API.add 'service/jct/funder/:iid', get: () -> return API.service.jct.funders this.urlParams.iid, this.queryParams.refresh

API.add 'service/jct/institution/:iid', 
  get: () -> 
    if res = wikidata_record.find 'snaks.property.exact:"P6782" AND snaks.value.exact:"' + this.urlParams.iid + '"'
      rc = {title: res.label}
      for s in res.snaks
        if s.property is 'P6782'
          rc.id = s.value
          break
      return rc
    else
      return undefined

API.add 'service/jct/ta', 
  get: () -> 
    if this.queryParams.issn or this.queryParams.journal
      return API.service.jct.ta this.queryParams.issn ? this.queryParams.journal, this.queryParams.institution ? this.queryParams.ror
    else
      return jct_agreement.search this.queryParams
API.add 'service/jct/ta/:issn', get: () -> return API.service.jct.ta this.urlParams.issn, this.queryParams.institution ? this.queryParams.ror
API.add 'service/jct/ta/institution', 
  csv: true
  get: () -> return API.service.jct.ta.institution()
API.add 'service/jct/ta/institution/:ror', get: () -> return API.service.jct.ta.institution this.queryParams.ror
API.add 'service/jct/ta/journal', 
  csv: true
  get: () -> return API.service.jct.ta.journal()
API.add 'service/jct/ta/journal/:issn', get: () -> return API.service.jct.ta.journal this.queryParams.issn
API.add 'service/jct/ta/agreements', 
  csv: true
  get: () -> return jct_agreement.fetch() # TODO change this to return a list of all the agreement IDs 
API.add 'service/jct/ta/agreements/:aid', 
  csv: true
  get: () -> return jct_agreement.fetch() # TODO change this to return a list of every journal and institution record for the agreement ID
API.add 'service/jct/ta/esac', # convenience for getting esac data from their web page, but not actually our direct source of TA data
  csv: true
  get: () -> return API.service.jct.ta.esac undefined, this.queryParams.refresh
API.add 'service/jct/ta/import', 
  get: () -> 
    Meteor.setTimeout (() => API.service.jct.ta.import()), 1
    return true

API.add 'service/jct/tj', # allow dump of all TJ?
  csv: true
  get: () -> return API.service.jct.tj this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/tj/:issn', get: () -> return API.service.jct.tj this.urlParams.issn , this.queryParams.refresh

API.add 'service/jct/doaj', 
  csv: true
  get: () -> return API.service.jct.doaj this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/doaj/:issn', get: () -> return API.service.jct.doaj this.urlParams.issn, this.queryParams.refresh

API.add 'service/jct/permission', get: () -> return API.service.jct.permission this.queryParams.issn
API.add 'service/jct/permission/:issn', get: () -> return API.service.jct.permission this.urlParams.issn

API.add 'service/jct/retention', get: () -> return API.service.jct.retention this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/retention/:issn', get: () -> return API.service.jct.retention this.urlParams.issn

API.add 'service/jct/feedback',
  get: () -> return API.service.jct.feedback this.queryParams
  post: () -> return API.service.jct.feedback this.bodyParams

API.add 'service/jct/examples', get: () -> return API.service.jct.examples()
API.add 'service/jct/test', get: () -> return API.service.jct.test this.queryParams



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



API.service.jct.suggest = (which='journal', q, from, size) ->
  if which is 'funder'
    res = []
    for f in API.service.jct.funders()
      matches = true
      if q isnt f.id
        for q in (if q then q.toLowerCase().split(' ') else []) # will this need to handle matching special chars?
          if q not in ['of','the','and'] and f.funder.toLowerCase().indexOf(q) is -1
            matches = false
      res.push({title: f.funder, id: f.id}) if matches
    return total: res.length, data: res
  else
    rs = API.service.academic[which].suggest q, from, size
    if which is 'institution'
      # here we provide institution names if they are present in the current TAs we know about
      titles = []
      ids = []
      res = []
      for f in API.service.jct.ta.institution()
        qs = []
        matches = true
        for qp in (if q then q.toLowerCase().split(' ') else []) # will this need to handle matching special chars?
          if qp not in ['of','the','and','university']
            qs.push(qp) if qp not in qs
            if f.title.toLowerCase().indexOf(qp) is -1 and f.id.toLowerCase().indexOf(qp) is -1
              matches = false
        if matches and f.title.toLowerCase() not in titles and f.id not in ids
          if qs.length and f.title.toLowerCase().replace('the ','').replace('university ','').replace('of ','').replace('and ','').indexOf(qs[0]) is 0
            res.unshift f
          else
            res.push f
          titles.push f.title.toLowerCase()
          ids.push f.id
      for r in rs.data
        if r.title.toLowerCase() not in titles and r.id not in ids
          titles.push r.title.toLowerCase()
          ids.push r.id
          res.push r
    else
      res = rs.data
    return total: res.length, data: res


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
  

# check to see if we already know if a given set of entities is compliant
# and if so, check if that compliance is still valid now
API.service.jct.compliance = (funder, journal, institution, retention, checks=['permission', 'doaj', 'ta', 'tj'], refresh=86400000, noncompliant=true) ->
  checks = checks.split(',') if typeof checks is 'string'
  results = []
  return results if refresh is true or refresh is 0
  qr = if journal then 'journal.exact:"' + journal + '"' else ''
  if institution
    qr += ' OR ' if qr isnt ''
    qr += 'institution.exact:"' + institution + '"'
  if funder
    qr += ' OR ' if qr isnt ''
    qr += 'funder.exact:"' + funder + '"'
  if qr isnt ''
    qr = '(' + qr + ')' if qr.indexOf(' OR ') isnt -1
    qr += ' AND retention:' + retention if retention?
    qr += ' AND compliant:true' if noncompliant isnt true
    #qr += ' AND NOT cache:true'
    if refresh isnt false
      qr += ' AND createdAt:>' + Date.now() - (if typeof refresh is 'number' then refresh else 0)
    # get the most recent non-cached calculated compliances for this set of entities
    found = []
    for pre in jct_compliance.fetch qr, true
      if found.length is checks.length
        break
      if pre?.results? and pre.results.length
        for pr in pre.results
          if pr.route not in found and ((pr.route in ['tj','fully_oa'] and pr.issn is journal) or (pr.route is 'ta'and pr.issn is journal and pr.ror is institution) or (pr.route is 'self_archiving' and pr.issn is journal and pr.ror is institution and pr.funder is funder))
            delete pr.started
            delete pr.ended
            delete pr.took
            pr.cache = true
            found.push(pr.route) if pr.route not in found
            results.push pr
  return results


  
API.service.jct.calculate = (params={}, refresh, checks=['permission', 'doaj', 'ta', 'tj'], retention=true) -> # TODO change retention to true when ready
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
    results: []

  for p in ['funder','journal','institution']
    params[p] = params[p].toString() if typeof params[p] is 'number'
    params[p] = params[p].split(',') if typeof params[p] is 'string' and params[p].indexOf(',') isnt -1
    if typeof params[p] is 'string' and (params[p].indexOf(' ') isnt -1 or (p is 'journal' and params[p].indexOf('-') is -1))
      try
        ad = API.service.jct.suggest(p, params[p]).data[0]
        params[p] = ad.id
        res.request[p].push {id: params[p], title: ad.title, issn: ad.issn, publisher: ad.publisher}
    params[p] = [params[p]] if typeof params[p] is 'string'
    params[p] ?= []
    if not res.request[p].length
      for v in params[p]
        try
          if rec = API.service.jct.suggest(p, v).data[0]
            res.request[p].push {id: rec.id, title: rec.title, issn: rec.issn, publisher: rec.publisher}
          else
            res.request[p].push {id: params[p][v]}
        catch
          res.request[p].push {id: params[p][v]}

  rq = Random.id() # random ID to store with the cached results, to measure number of unique requests that aggregate multiple sets of entities
  checked = 0
  _check = (funder, journal, institution) ->
    hascompliant = false
    _results = []
    cr = permission: ('permission' in checks), doaj: ('doaj' in checks), ta: ('ta' in checks), tj: ('tj' in checks)

    # look for cached results for the same values in jct_compliance - if found, use them, and don't recheck permission types already found there
    try
      for pr in pre = API.service.jct.compliance funder, journal, institution, retention, checks, refresh
        hascompliant = true if pr.compliant is 'yes'
        cr[if pr.route is 'fully_oa' then 'doaj' else if pr.route is 'self_archiving' then 'permission' else pr.route] = false
        _results.push pr

    _rtn = {}
    _ck = (which) ->
      Meteor.setTimeout () ->
        try
          if rs = API.service.jct[which] journal, (if institution? and which in ['permission','ta'] then institution else undefined)
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
        catch
          cr[which] = false
      , 1
    for c in checks
      _ck(c) if cr[c]

    while cr.permission is true or cr.doaj is true or cr.ta is true or cr.tj is true
      future = new Future()
      Meteor.setTimeout (() -> future.return()), 100
      future.wait()
    res.compliant = true if hascompliant
    try
      # store a new set of results every time without removing old ones, to keep track of incoming request amounts
      jct_compliance.insert journal: journal, funder: funder, institution: institution, retention: retention, rq: rq, checks: checks, compliant: hascompliant, cache: (if pre? then true else false), results: _results
    res.results.push(rs) for rs in _results

    checked += 1

  combos = [] # make a list of all possible valid combos of params
  for j in (if params.journal and params.journal.length then params.journal else [undefined])
    cm = journal: j
    for f in (if params.funder and params.funder.length then params.funder else [undefined]) # does funder have any effect? - probably not right now, so the check will treat them the same
      cm.funder = f
      for i in (if params.institution and params.institution.length then params.institution else [undefined])
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



# For a TA to be in force, an agreement record for the the ISSN and also one for 
# the ROR mus be found, and the current date must be after those record start dates 
# and before those record end dates. A journal and institution could be in more than 
# one TA at a time - return all cases where both journal and institution are in the 
# same TA
API.service.jct.ta = (issn, ror, at) ->
  tas = []
  res =
    started: Date.now()
    ended: undefined
    took: undefined
    route: 'ta'
    compliant: 'unknown'
    qualifications: undefined
    issn: issn
    ror: ror
    log: [{action: 'Check transformative agreements for currently active agreement containing journal and institution'}]
  at ?= res.started
  # what if start or end dates do not exist, but at least one of them does? Must they all exist?
  qr = ''
  qr += 'issn.exact:"' + issn + '"' if issn
  if ror
    qr += ' OR ' if qr isnt ''
    qr += 'ror.exact:"' + ror + '"'
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
  for j of journals # is this likely to be longer than institutions?
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
        rs.log[0].result = 'A currently active transformative agreement containing the journal and institution was found - ' + institutions[j].rid
        rs.ended = Date.now()
        rs.took = rs.ended-rs.started
        tas.push rs
  if tas.length is 0
    res.compliant = 'no'
    res.log[0].result = 'There are no current transformative agreements containing the journal and institution'
    res.ended = Date.now()
    res.took = res.ended-res.started
    tas.push res
  return if tas.length is 1 then tas[0] else tas

#API.service.jct.ta._esac = false
API.service.jct.ta.esac = (id,refresh) ->
  res = []
  #if API.service.jct.ta._esac isnt false and refresh isnt true
  #  res = API.service.jct.ta._esac
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'jct', 'esac', undefined, refresh
    res = cached
  else
    try
      for r in API.convert.table2json API.http.puppeteer 'https://esac-initiative.org/about/transformative-agreements/agreement-registry/'
        rec =
          publisher: r.Publisher.trim()
          country: r.Country.trim()
          organization: r.Organization.trim()
          size: r["Annual publications"].trim()
          start_date: r["Start date"].trim()
          end_date: r["End date"].trim()
          id: r["Details/ ID"].trim()
        rec.url = 'https://esac-initiative.org/about/transformative-agreements/agreement-registry/' + rec.id
        rec.startAt = moment(rec.start_date, 'MM/DD/YYYY').valueOf()
        rec.endAt = moment(rec.end_date, 'MM/DD/YYYY').valueOf()
        try
          rs = parseInt rec.size
          if typeof rs is 'number' and not isNaN rs
            rec.size = sz
        res.push rec
      #API.service.jct.ta._esac = res
      API.http.cache 'jct', 'esac', res

  if id?
    res = undefined
    for e in res
      res = e if e.id is id
  return res

API.service.jct.ta.institution = (ror) ->
  res = []
  seen = []
  jct_agreement.each 'institution:*', (rec) ->
    if not ror? or (ror and rec.ror is ror) and rec.ror not in seen
      seen.push rec.ror
      res.push title: rec.institution, id: rec.ror
  return res

API.service.jct.ta.journal = (issn) ->
  res = []
  seen = []
  jct_agreement.each 'journal:*', (rec) ->
    if not issn or (issn and issn in rec.issn)
      seen.push(isn) for isn in rec.issn
      res.push title: rec.journal, id: (issn ? rec.issn[0]), issn: rec.issn
  return res
    
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
  for ov in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=1130349201&single=true&output=csv'
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
            inaj = false
            fnd = []
            for ic in _.clone rec.issn
              if ic not in fnd
                fnd.push ic
                if af = academic_journal.find 'issn.exact:"' + ic + '"'
                  inaj = true
                  for an in af.issn
                    fnd.push an
                    rec.issn.push(an) if an not in rec.issn
            if not inaj
              # add the ISSN to the journal index
              academic_journal.insert src: 'jct', issn: rec.issn, title: rec.journal # note these will have no publisher name
            records.push rec
  if records.length
    console.log 'Removing and reloading ' + records.length + ' agreements'
    jct_agreement.remove '*'
    jct_agreement.insert records
    res.extracted = records.length
  if mail
    API.mail.send
      from: 'nobody@cottagelabs.com'
      to: 'jct@cottagelabs.com'
      subject: 'JCT TA import complete' + (if API.settings.dev then ' (dev)' else '')
      text: JSON.stringify res, '', 2
    if bads.length
      API.mail.send
        from: 'nobody@cottagelabs.com'
        to: 'jct@cottagelabs.com'
        subject: 'JCT TA import found ' + bads.length + ' bad ISSNs' + (if API.settings.dev then ' (dev)' else '')
        text: JSON.stringify bads, '', 2
  return res



# import transformative journals data, which should indicate if the journal IS 
# transformative or just in the list for tracking (to be transformative means to 
# have submitted to the list with the appropriate responses)
# fields called pissn and eissn will contain ISSNs to check against

# check if an issn is in the transformative journals list (to be provided by plan S)
API.service.jct.tj = (issn, refresh=86400000) -> # refresh each day?
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
        if not _.isEmpty tj
          fnd = []
          for ic in _.clone tj.issn ? []
            if ic not in fnd
              fnd.push ic
              if af = academic_journal.find 'issn.exact:"' + ic + '"'
                for an in af.issn
                  fnd.push an
                  tj.issn.push(an) if an not in tj.issn
          tjs.push tj
      API.http.cache 'jct', 'tj', tjs

  if issn
    res = 
      started: Date.now()
      ended: undefined
      took: undefined
      route: 'tj'
      compliant: 'unknown'
      qualifications: undefined
      issn: issn
      log: [{action: 'Check transformative journals list for journal'}]

    issns = []
    for t in tjs
      for isn in t.issn
        issns.push(isn) if isn not in issns
    if issn in issns
      res.compliant = 'yes'
      res.log[0].result = 'Journal found in transformative journals list'
      # is there any URL to link back to for a TJ
    else
      res.compliant = 'no'
      res.log[0].result = 'Journal is not in transformative journals list'
    res.ended = Date.now()
    res.took = res.ended-res.started
    return res
  else
    return tjs



# what are these qualifications relevant to? TAs?
# there is no funder qualification done now, due to retention policy change decision at ened of October 2020. May be added again later.
# rights_retention_author_advice - 
# rights_retention_funder_implementation - the journal does not have an SA policy and the funder has a rights retention policy that starts in the future. There should be one record of this per funder that meets the conditions, and the following qualification specific data is requried:
# funder: <funder name>
# date: <date policy comes into force (YYYY-MM-DD)
API.service.jct._retention = false
API.service.jct.retention = (journal, refresh) ->
  # check the rights retention data source once it exists if the record is not in OAB
  # for now this is not used directly, just a fallback to something that is not in OAB
  # will be a list of journals by ISSN and a number 1,2,3,4,5
  # import them if not yet present (and probably do some caching)
  rets = []
  if API.service.jct._retention isnt false and refresh isnt true
    rets = API.service.jct._retention
  else
    for rt in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTVZwZtdYSUFfKVRGO3jumQcLEjtnbdbw7yJ4LvfC2noYn3IwuTDjA9CEjzSaZjX8QVkWijqa3rmicY/pub?gid=0&single=true&output=csv'
      rt.journal = rt['Journal Name'].trim() if typeof rt['Journal Name'] is 'string'
      rt.issn = []
      rt.issn.push(rt['ISSN (print)'].trim()) if typeof rt['ISSN (print)'] is 'string' and rt['ISSN (print)'].length
      rt.issn.push(rt['ISSN (online)'].trim()) if typeof rt['ISSN (online)'] is 'string'and rt['ISSN (online)'].length
      rt.position = if typeof rt.Position is 'number' then rt.Position else parseInt rt.Position.trim()
      rt.publisher = rt.Publisher.trim() if typeof rt.Publisher is 'string'
      rets.push(rt) if rt.issn.length and rt.position? and typeof rt.position is 'number' and rt.position isnt null and not isNaN rt.position

  if journal
    res =
      started: Date.now()
      ended: undefined
      took: undefined
      route: 'retention' # this is actually only used as a subset of OAB permission self_archiving so far
      compliant: 'yes' # if not present then compliant but with author and funder quals - so what are the default funder quals?
      qualifications: [{'rights_retention_author_advice': ''}]
      issn: journal
      log: [{action: 'Check for author rights retention', result: 'Rights retention not found, so default compliant'}]
    for ret in rets
      if journal in ret.issn
        if ret.position is 5 # if present and 5, not compliant
          delete res.qualifications
          res.log[0].result = 'Rights retention number ' + ret.position + ' so not compliant'
          res.compliant = 'no'
        else
          res.log[0].result = 'Rights retention number ' + ret.position + ' so compliant' #, but check funder qualifications if any'
          # for some reason, we now leave the same author advice that the journal does not appear in the data source even if the 
          # data source is the thing telling us the number is 1 to 4... that's what was asked so that is what I will do.
          # https://github.com/antleaf/jct-project/issues/215#issuecomment-726761965
          # if present and any other number, or no answer, then compliant with some funder quals - so what funder quals to add?
          # no funder quals now due to change at end of October 2020. May be introduced again later
        break
    res.ended = Date.now()
    res.took = res.ended-res.started
    return res
  else
    return rets



API.service.jct.permission = (journal, institution) ->
  res =
    started: Date.now()
    ended: undefined
    took: undefined
    route: 'self_archiving'
    compliant: 'unknown'
    qualifications: undefined
    issn: journal
    ror: institution
    funder: undefined
    log: [{action: 'Check Open Access Button Permissions for journal'}]

  try
    perms = API.service.oab.permission {issn: journal, ror: institution}, undefined, undefined, undefined, undefined, false
    if perms.best_permission?
      res.compliant = 'no' # set to no until a successful route through is found
      pb = perms.best_permission
      res.log[0].result = if pb.journal_is_oa then 'The journal is Open Access' else if pb.issuer?.type is 'journal' then 'The journal is in OAB Permissions' else 'The publisher of the journal is in OAB Permissions'
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

  res.ended = Date.now()
  res.took = res.ended-res.started
  return res



# import doaj data including applications in progress, to find journals in or soon to be in it
API.service.jct.doaj = (issn, refresh=864000000) ->
  # refresh in ten days if not refreshed before (this was every day, but delayed so 
  # that will actually get refreshed in timing along with when DOAJ data updates on the main import run)
  
  # adding this here rather than in DOAJ service user because this part of DOAJ 
  # API exists exclusively for JCT. Can move later if suitable
  # add a cache to this with a suitable refresh
  progs = []
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'jct', 'doaj_in_progress', undefined, refresh
    progs = cached
  else
    try
      r = HTTP.call 'GET', 'https://doaj.org/jct/inprogress?api_key=' + API.settings.service.jct.doaj.apikey
      rc = JSON.parse r.content
      API.http.cache 'jct', 'doaj_in_progress', rc
      progs = rc

  if issn
    missing = []
    res =
      started: Date.now()
      ended: undefined
      took: undefined
      route: 'fully_oa'
      compliant: 'unknown'
      qualifications: undefined
      issn: issn
      log: [{action: 'Check DOAJ applications in case the journal recently applied to be in DOAJ', result: 'Journal does not have an open application to be in DOAJ'}]

    for p in progs # check if there is an open application for the journal to join DOAJ
      if p.pissn is issn or p.eissn is issn
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
      if db = academic_journal.find 'issn.exact:"' + issn + '" AND src.exact:"doaj"'
        res.log[1].result = 'The journal has been found in DOAJ'
        res.log.push action: 'Check if the journal has a suitable licence' # only do licence check for now
        # Publishing License	bibjson.license[].type	bibjson.license[].type	CC BY, CC BY SA, CC0	CC BY ND
        pl = false
        if db.license? and db.license.length
          for bl in db.license
            if typeof bl?.type is 'string' and bl.type.toLowerCase().trim().replace(/ /g,'').replace(/-/g,'') in ['ccby','ccbysa','cc0','ccbynd']
              pl = bl.type
              break
        if not db.licence?
          res.log[2].result = 'Licence data is missing, compliance cannot be calculated'
          missing.push 'licence'
        else if pl
          res.log[2].result = 'The journal has a suitable licence: ' + pl
          res.compliant = 'yes'
        else
          res.log[2].result = 'The journal does not have a suitable licence'
          res.compliant = 'no'

        ''' simplify to only check licence for the time being - the rest of these full checks may be added later so keep the code for now.
        res.log.push action: 'Check if the DOAJ indicates the author retains copyright'
        # must have Editorial policies (true if in DOAJ anyway) and Embargo has to be 0 which is implicitly true if in DOAJ anyway
        # there are two ways to check each of the following because DOAJ is soon changing format so cover both for now
        # Author retains copyright	bibjson.author_copyright.copyright="True"	bibjson.copyright.author_retains=true
        # Version allowed for SA and Allowed SA Licence are	inferred from Author retains copyright
        if not db.author_copyright?.copyright? and not db.copyright?.author_retains?
          res.log[2].result = 'Author copyright retention data is missing, compliance cannot be calculated'
          missing.push 'copyright.author_retains'
        else if db.author_copyright?.copyright is 'True' or db.copyright?.author_retains is true
          res.log[2].result = 'The author retains copyright'
          res.log.push action: 'Check if the journal has an archiving/preservation policy'
          # Preservation	something in bibjson.archiving_policy.known[]	OR value in bibjson.archiving_policy.nat_lib OR a value in bibjson.archiving_policy.other
          if not db.archiving_policy? and not db.archiving_policy.nat_lib and not db.archiving_policy.other and not db.preservation?.has_preservation?
            res.log[3].result = 'Archiving preservation policy data is missing, compliance cannot be calculated'
            missing.push 'preservation.has_preservation'
          else if (db.archiving_policy?.known? and db.archiving_policy.known.length) or (db.archiving_policy.nat_lib? and db.archiving_policy.nat_lib.length) or (db.archiving_policy.other? and db.archiving_policy.other.length) or db.preservation?.has_preservation is true
            res.log[3].result = 'The journal does have an archiving/preservation policy'
            res.log.push action: 'Check if the journal provides article processing charge information URL'
            # Pricing information	bibjson.apc_url OR bibjson.submission_charges_url	TODO
            if not db.apc_url? and not db.submission_charges_url?
              res.log[4].result = 'APC submission charges data is missing, compliance cannot be calculated'
              missing.push 'submission_charges_url'
            else if db.apc_url or db.submission_charges_url
              res.log[4].result = 'An APC URL is available'
              res.log[4].url = db.apc_url ? db.submission_charges_url
              res.log.push action: 'Check if the journal uses a persistent identifier scheme'
              # Uses PIDs	bibjson.persistent_identifier_scheme[]	bibjson.pid_scheme.scheme[]
              if not db.persistent_identifier_scheme? and not db.pid_scheme.scheme?
                res.log[5].result = 'Persistent identifier scheme data is missing, compliance cannot be calculated'
                missing.push 'pid_scheme.scheme'
              else if (db.persistent_identifier_scheme? and db.persistent_identifier_scheme.length) or (db.pid_scheme?.scheme? and db.pid_scheme.scheme.length)
                res.log[5].result = 'The journal uses a PID scheme'
                res.log.push action: 'Check if the journal provides a suitable waiver policy'
                # Waiver policy	bibjson.link.url where bibjson.link.type="waiver_policy"	bibjson.waiver.has_waiver=true
                hw = db.waiver?.has_waiver is true
                if hw is false and db.link? and db.link.length
                  for wl in db.link
                    if wl.type is 'waiver_policy' and wl.url?
                      hw = true
                      break
                if not db.waiver?.has_waiver? and not db.link?
                  res.log[6].result = 'Waiver policy data is missing, compliance cannot be calculated'
                  missing.push 'waiver.has_waiver'
                else if hw
                  res.log[6].result = 'The journal has a waiver policy'
                  res.log.push action: 'Check if the journal has a suitable licence'
                  # Publishing License	bibjson.license[].type	bibjson.license[].type	CC BY, CC BY SA, CC0	CC BY ND
                  pl = false
                  if db.license? and db.license.length
                    for bl in db.license
                      if typeof bl?.type is 'string' and bl.type.toLowerCase().trim().replace(/ /g,'').replace(/-/g,'') in ['ccby','ccbysa','cc0','ccbynd']
                        pl = bl.type
                        break
                  if not db.licence?
                    res.log[7].result = 'Licence data is missing, compliance cannot be calculated'
                    missing.push 'licence'
                  else if pl
                    res.log[7].result = 'The journal has a suitable licence: ' + pl
                    res.log.push action: 'Check if the journal has an embedded licence'
                    # License embedded	bibjson.license[].embedded:true	bibjson.article.license_display contains "Embed"
                    acceptable = db.article?.license_display is 'string' and db.article.license_display.toLowerCase().indexOf('embed') isnt -1
                    if not acceptable and db.license? and db.license.length
                      for lnc in db.license
                        if lnc.embedded is true
                          acceptable = true
                          break
                    if not db.license? and not db.article?.license_display?
                      res.log[8].result = 'Embedded licence data is missing, compliance cannot be calculated'
                      missing.push 'article.license_display'
                    else if acceptable
                      res.log[8].result = 'The journal has an embedded licence'
                      res.compliant = 'yes'
                      res.url = 'https://doaj.org/toc/' + issn
                    else
                      res.log[8].result = 'The journal does not have an embedded licence'
                      res.compliant = 'no'
                  else
                    res.log[7].result = 'The journal does not have a suitable licence'
                    res.compliant = 'no'
                else
                  res.log[6].result = 'The journal does not have a waiver policy'
                  res.compliant = 'no'
              else
                res.log[5].result = 'The journal does not use a suitable PID scheme'
                res.compliant = 'no'
            else
              res.log[4].result = 'The journal does not provide an APC URL'
              res.compliant = 'no'
          else
            res.log[3].result = 'The journal does not have a suitable archiving/preservation policy'
            res.compliant = 'no'
        else
          res.log[2].result = 'The author does not retain copyright'
          res.compliant = 'no' '''
      else
        res.log[1].result = 'Journal is not in DOAJ'
        res.compliant = 'no'
    res.ended = Date.now()
    res.took = res.ended-res.started
    #if missing.length
    #  try API.service.jct.feedback name: 'system', email: 'jct@cottagelabs.com', feedback: 'Missing DOAJ data', context: missing
    return res
  else
    return progs



# https://www.coalition-s.org/plan-s-funders-implementation/
#API.service.jct._funders = false
API.service.jct.funders = (id,refresh) ->
  res = []

  #if API.service.jct._funders isnt false and refresh isnt true
  #  res = API.service.jct._funders
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
      #API.service.jct._funders = res
      API.http.cache 'jct', 'funders', res

  if id?
    for e in res
      if e.id is id
        res = e
        break
  return res
Meteor.setTimeout API.service.jct.funders, 6000 # get the funders at every startup


  
API.service.jct.import = (params={}) ->
  # run all imports necessary for up to date data
  params[p] ?= true for p in ['retention', 'funders', 'journals', 'doaj', 'ta', 'tj']
  res = {}
  if params.journals
    # or a new load of all journals? or include crossref? what about source files?
    # doaj only updates their journal dump once a week so calling academic journal load
    # won't actually do anything if the dump file name has not changed since last run 
    # or if a refresh is called
    res.journals = API.service.academic.journal.load ['doaj'] # crossref?
  if params.doaj and res.journals?.processed
    # only get new doaj inprogress data if the journals load processed some doaj 
    # journals (otherwise we're between the week-long period when doaj doesn't update)
    res.doaj = API.service.jct.doaj undefined, true
  if params.ta
    res.ta = API.service.jct.ta.import false
  if params.tj
    res.tj = API.service.jct.tj undefined, true
  if params.retention
    res.retention = API.service.jct.retention undefined, true
  if params.funders
    API.service.jct.funders undefined, true
  # institution lists?
  # anything in OAB to trigger?
  API.mail.send
    from: 'nobody@cottagelabs.com'
    to: 'jct@cottagelabs.com'
    subject: 'JCT import complete' + (if API.settings.dev then ' (dev)' else '')
    text: JSON.stringify res, '', 2
  return res
  

# run import every day on the main machine
_jct_import = () ->
  if API.settings.cluster?.ip? and API.status.ip() not in API.settings.cluster.ip
    API.log 'Setting up a JCT import to run every day if not triggered by request on ' + API.status.ip()
    Meteor.setInterval (() ->
      newest = jct_agreement.find '*', true
      if newest?.createdAt < Date.now()-86400000
        API.service.jct.import()
      ), 43200000
Meteor.setTimeout _jct_import, 18000



API.service.jct.examples = () ->
  return {}

# set up a test on difftest or a cron or by URL trigger as necessary. Expected test results:
# https://docs.google.com/document/d/1AZX_m8EAlnqnGWUYDjKmUsaIxnUh3EOuut9kZKO3d78/edit
API.service.jct.test = (params={}) ->
  # A series of queries based on journals, with existing knowledge of their policies. 
  # To test TJ and Rights retention elements of the algorithm some made up information is included, 
  # this is marked with [1]. Not all queries test all the compliance routes (in particular rights retention).
  # Expected JCT Outcome, is what the outcome should be based on reading the information within journal, institution and funder data. 
  # Actual JCT Outcome is what was obtained by walking through the algorithm under the assumption that 
  # the publicly available information is within the JCT data sources.
  res = []

  queries =
    one: # Query 1
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc TA)
      institution: 'Cardiff University' # (subscriber to Jisc TA)
      funder: 'Wellcome'
      'expected outcome': 'Researcher can publish via gold open access route or via TA'
      qualification: 'Researcher must be corresponding author to be eligible for TA'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and r.qualification?corresponding_authors?
    two: # Query 2
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc TA)
      institution: 'Emory University' # (no TA or Wiley agreement)
      funder: 'Wellcome'
      'expected outcome': 'Researcher can publish via gold open access route'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant
    three: # Query 3
      journal: 'Aging Cell' # (published by Wiley, fully OA, in DOAJ, CC BY, included within UK Jisc & VSNU TAs)
      institution: ['Emory University', 'Cardiff University', 'Utrecht University'] # (Emory has no TA or Wiley account, Cardiff is subscriber to Jisc TA, Utrecht is subscriber to VSNU TA)
      funder: ['Wellcome', 'Wellcome', 'NWO']
      'expected outcome': 'For Cardiff and Utrecht: Researcher can publish via gold open access route or via TA (Qualification: Researcher must be corresponding author to be eligible for TA). For Emory: Researcher can publish via gold open access route'
      'actual outcome': 'As expected'
      test: (r) ->
        return 'TODO'
    four: # Query 4
      journal: 'Proceedings of the Royal Society B' # (subscription journal published by Royal Society, AAM can be shared CC BY no embargo, UK Jisc Read Publish Deal)
      institution: 'University of Cambridge' # (subscribe to Read Publish Deal)
      funder: 'EC'
      'expected outcome': 'Researcher can self-archive or publish via Read Publish Deal'
      qualification: 'Research must be corresponding author to be eligible for Read Publish Deal'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant and r.qualification?corresponding_authors?
    five: # Query 5
      journal: 'Proceedings of the Royal Society B' # (subscription journal published by Royal Society, AAM can be shared CC BY no embargo, UK Jisc Read Publish Deal)
      institution: 'University of Cape Town'
      funder: 'BMGF'
      'expected outcome': 'Researcher can self-archive'
      'actual outcome': 'As expected'
      test: (r) -> return r.compliant
    six: # Query 6
      journal: 'Development' # (Transformative Journal, AAM 12 month embargo) 0951-1991
      institution: 'University of Cape Town'
      funder: 'SAMRC'
      'expected outcome': 'Researcher can publish via payment of APC (Transformative Journal) or self-archive the AAM via rights retention.'
      qualification: 'Researcher must inform publisher of funder and pre-existing CC BY licence on manuscript at point of submission.'
      'actual outcome': 'As expected'
      test: (r) -> return 'TODO'
    seven: # Query 7
      journal: 'Brill Research Perspectives in Law and Religion' # (Subscription Journal, VSNU Read Publish Agreement, AAM can be shared CC BY-NC no embargo, Option 4 Rights Retention Policy [1])
      institution: 'University of Amsterdam' # (not subscribed to Brill VSNU Agreement)
      funder: 'NWO'
      'expected outcome': 'Researcher can self-archive the AAM via rights retention.'
      qualification: 'Researcher must inform publisher of funder and pre-existing CC BY licence on manuscript at point of submission.'
      'actual outcome': 'As expected'
      test: (r) -> return 'TODO'
    eight: # Query 8
      journal: 'Migration and Society' # (Subscribe to Open, CC BY, CC BY-ND and CC BY-NC-ND licences available but currently only CC BY-NC-ND in DOAJ)
      institution: 'University of Vienna'
      funder: 'FWF'
      'expected outcome': 'No routes to compliance'
      'actual outcome': 'As expected'
      test: (r) -> return 'TODO'
    nine: # Query 9 
      journal: 'Folia Historica Cracoviensia' # (fully oa, in DOAJ, CC BY-NC-ND, No known prior notification of rights retention [1])
      institution: ['University of Warsaw', 'University of Ljubljana']
      funder: ['NCN', 'ARRS'] # (NCN is early adopter of Rights Retention, ARRS is adoption to follow Rights Retention)
      'expected outcome': 'For NCN: Researcher can self-archive the AAM via rights retention. For ARRS: No route to compliance.'
      qualification: 'Researcher must inform publisher of funder and pre-existing CC BY licence on manuscript at point of submission.'
      'actual outcome': 'As expected'
      test: (r) -> return 'TODO'
    ten: # Query 10
      journal: 'Journal of Clinical Investigation' # (subscription for front end material, research articles: publication fee, no embargo, CC BY licence where required by funders, not in DOAJ, Option 5 Rights Retention Policy [1])
      institution: 'University of Vienna'
      funder: 'FWF'
      'expected outcome': 'Researcher can publish via standard publication route'
      'actual outcome': 'Researcher cannot publish in this journal and comply with funders OA policy'
      test: (r) -> return 'TODO'

  for q of queries
    qr = queries[q]
    ans = query: q
    ans['pass/fail'] = 'fail'
    ans.inputs = queries[q]
    ans.discovered = {}
    try ans.discovered.issn = API.service.jct.suggest('journal', qr.journal).data[0].id
    try ans.discovered.ror = API.service.jct.suggest('institution', qr.institution).data[0].id
    try ans.discovered.funder = API.service.jct.suggest('funder', qr.funder).data[0].id
    ans.result = API.service.jct.calculate {funder: ans.discovered.funder, journal: ans.discovered.issn, institution: ans.discovered.ror}, params.refresh, params.checks, params.retention
    ans['pass/fail'] = queries[q].test ans.result
    res.push ans
    
  return res



# list of ~200 publishers that JCT wants to track
# https://docs.google.com/spreadsheets/d/1HuYCF1Octp9aOZfD4Gn2VT4-LE6qikfq/edit#gid=691103640
# copied manually for now until we have a sheet that can be public and directly attached to
API.service.jct._publishers = ['Academic Press Inc.',
'ACHEMENET',
'Acoustical Society of America',
'Akademiai Kiado',
'American Association for Cancer Research (AACR)',
'American Association for the Advancement of Science (AAAS)',
'American Association of Immunologists',
'American Chemical Society (ACS)',
'American Diabetes Association',
'American Economic Association',
'AMERICAN GEOPHYSICAL UNION (AGU)',
'AMERICAN HEART ASSOCIATION',
'American Institute of Aeronautics and Astronautics',
'American Institute of Mathematical Sciences',
'American Institute of Physics',
'American Mathematical Society',
'American Medical Association (AMA)',
'American Meteorological Society',
'American Physical Society',
'American Physiological Society',
'American Phytopathological Society',
'American Psychological Association',
'American Scientific Publishers',
'American Society for Biochemistry & Molecular Biology (ASBMB)',
'American Society for Cell Biology',
'American Society for Clinical Investigation',
'American Society for Clinical Nutrition, Inc.',
'American Society for Microbiology',
'AMERICAN SOCIETY FOR PHARMACOLOGY AND EXPERIMENTAL THERAPEUTICS (ASPET)',
'American Society of Civil Engineers',
'American Society of Hematology',
'American Society of Mechanical Engineers',
'American Society of Nephrology',
'American Society of Plant Biologists',
'American Society of Tropical Medicine and Hygiene',
'American Thoracic Society',
'Annual Reviews',
'ARCHIVE OF FORMAL PROOFS',
'Association for Computing Machinery',
'Association for Research in Vision and Ophthalmology',
'Baltzer Science Publishers B.V.',
'Beilstein-Institut Zur Forderung der Chemischen Wissenschaften',
'Bentham Science Publishers',
'Bill & Melinda Gates Foundation',
'BioMed Central',
'Biophysical Society',
'BioScientifica Ltd.',
'Birkhauser Verlag AG',
'BMJ Publishing Group Ltd',
'Brepols Publishers NV',
'Brill Academic Publishers',
'Cambridge University Press',
'Carfax Publishing Ltd.',
'Cell Press',
'Centers for Disease Control and Prevention (CDC)',
'CEUR WORKSHOP PROCEEDINGS',
'Chinese Science Publishing & Media Ltd. (Science Press Ltd.)',
'Churchill Livingstone',
'Cold Spring Harbor Laboratory',
'Commonwealth Scientific and Industrial Research Organization Publishing (CSIRO Publishing)',
'Company of Biologists Ltd',
'Copernicus Publications',
'CSIC Consejo Superior de Investigaciones Cientificas',
'D. Reidel Pub. Co.',
'Walter de Gruyter GmbH',
'DISCRETE MATHEMATICS & THEORETICAL COMPUTER SCIENCE',
'Dove Medical Press Ltd.',
'Dr. Dietrich Steinkopff Verlag',
'Duke University Press',
'Duodecim',
'Edinburgh University Global Health Society',
'EDP Sciences',
'Electrochemical Society, Inc.',
'ELEMENT D.O.O.',
'eLife Sciences Publications, Ltd',
'Elsevier',
'EMBO',
'Emerald Group Publishing Ltd.',
'ENDOCRINE SOCIETY',
'European Centre for Disease Prevention and Control (ECDC)',
'EUROPEAN GEOSCIENCES UNION',
'European Language Resources Association (ELRA)',
'European Mathematical Society Publishing House',
'European Respiratory Society',
'F1000 Research Ltd',
'Federation of American Societies for Experimental Biology',
'Ferrata Storti Foundation',
'Frank Cass Publishers',
'FRONTIERS MEDIA',
'Future Medicine Ltd',
'Genetics Society of America',
'Geological Society of America',
'Georg Thieme Verlag',
'Gordon and Breach Science Publishers',
'Hindawi',
'HOLZHAUSEN',
'Humana Press, Inc.',
'IFAC Secretariat',
'Impact Journals, LLC',
'Inderscience Publishers',
'Informa Healthcare',
'Informa UK Limited',
'INSTITUTE FOR OPERATIONS RESEARCH AND THE MANAGEMENT SCIENCES (INFORMS)',
'Institute of Electrical and Electronics Engineers Inc. (IEEE)',
'Institute of Mathematical Statistics',
'Institute of Physics',
'Institute of Physics and the Physical Society',
'Institution of Engineering and Technology',
'International Press of Boston, Inc.',
'International Society of Global Health',
'International Union Against Tuberculosis and Lung Disease',
'International Union of Crystallography',
'International Water Association Publishing',
'Inter-Research Science Publishing',
'IOS Press',
'Italian Association of Chemical Engineering - AIDIC',
'IWA Publishing',
'Jagiellonian University Press',
'Japan Society of Applied Physics',
'John Benjamins Publishing Company',
'KARGER [S. Karger AG]',
'Kexue Chubaneshe/Science Press',
'Kluwer Academic Publishers',
'Landes Bioscience',
'Lawrence Erlbaum Associates Inc.',
'Lippencott Williams Wilkins [Lippincott]',
'MAGNOLIA PRESS',
'Maik Nauka Publishing / Springer SBM',
'Maik Nauka/Interperiodica Publishing',
'Maney Publishing',
'Marcel Dekker Inc.',
'Mary Ann Liebert Inc.',
'MASARYK UNIVERSITY',
'Massachusetts Medical Society',
'Masson Publishing',
'Masson SpA',
'Mathematical Sciences Publishers',
'Max-Planck Institute for Demographic Research/Max-Planck-institut fur Demografische Forschung',
'MDPI Open Access Publishing',
'Microbiology Society',
'MINERALOGICAL SOCIETY OF AMERICA',
'MIT Press',
'Mosby Inc.',
'Multidisciplinary Digital Publishing Institute (MDPI)',
'MyJove Corporation',
'National Academy of Sciences',
'Nature Publishing (Nature Research - division of Springer Nature) UK office. Other offices worldwide -see Palgrave Macmillan below',
'NRC Research Press',
'OLDENBOURG VERLAG (part of De Gruyter)',
'OPEN PUBLISHING ASSOCIATION [OA publisher]',
'Optical Society of America',
'OSA Publishing',
'ÖSTERREICHISCHEN AKADEMIE DER WISSENSCHAFTEN (ÖAW)',
'Ovid Technologies (Wolters Kluwer Health)',
'Oxford University Press (OUP)',
'Palgrave Macmillan Ltd. (Part of Springer Nature see also NPG above)',
'PeerJ [OA publisher]',
'PEETERS',
'PENSOFT PUBLISHERS',
'Plenum Publishers',
'POLISH ACADEMY OF SCIENCES',
'Polska Akademia Nauk',
'Portland Press, Ltd.',
'Proceedings of the National Academy of Sciences',
'PUBLIC KNOWLEDGE PROJECT',
'Public Library of Science (PLoS)',
'Rockefeller University Press',
'Routledge',
'Royal Society of Chemistry (RSC)',
'S P I E - International Society for Optical Engineering',
'S. Karger AG',
'SAGE Publications Ltd',
'SCHATTAUER',
'Schloss Dagstuhl- Leibniz-Zentrum fur Informatik GmbH, Dagstuhl Publishing',
'Schweizerische Chemische Gedellschaft',
'SCIENTIFIC RESEARCH PUBLISHING',
'Seismological Society of America',
'SISSA',
'Società Italiana di Fisica',
'Society for General Microbiology',
'SCHWEIZERBART UND BORNTRAEGER',
'Society for Industrial and Applied Mathematics',
'SOCIETY FOR LEUKOCYTE BIOLOGY',
'Society for Neuroscience',
'Society of Photo-Optical Instrumentation Engineers',
'South African Medical Research Journal',
'Springer',
'SPE',
'Springer Nature',
'StudienVerlag GMBH',
'Taylor & Francis',
'Technischen Universitat Braunschweig',
'The American Association of Immunologists',
'The Company of Biologists Ltd',
'THE ELECTRONIC JOURNAL OF COMBINATORICS',
'The Endocrine Society',
'The Johns Hopkins University Press',
'The Lancet Publishing Group',
'The Optical Society',
'The Resilience Alliance',
'The Royal Society',
'TRANS TECH PUBLICATIONS',
'UNIVERSIDAD DE NAVARRA',
'UNIVERSITÄT GRAZ',
'University of Chicago Press',
'US Department of Health and Human Services',
'W. B. Saunders Co., Ltd.',
'WHO',
'Wiley Blackwell'
]