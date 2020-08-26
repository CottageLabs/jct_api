
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

# define the jct service object in the overall API
API.service ?= {}
API.service.jct = {}



# define all web endpoints that the JCT requires - these are served on the main API, 
# but also will be directly routed from a dedicated domain, so that service/jct/ will 
# be unnecessary from that domain (and it will be routed via cloudlfare for caching too)
API.add 'service/jct', 
  get: () -> return API.service.jct.calculate this.queryParams
  post: () -> return API.service.jct.calculate this.bodyParams
API.add 'service/jct/calculate', 
  get: () -> return API.service.jct.calculate this.queryParams
  post: () -> return API.service.jct.calculate this.bodyParams
API.add 'service/jct/import', get: () -> return API.service.jct.import this.queryParams

# these should also be cached via cloudflare or similar, so that over time we build known lists of suggestions
# (and can preload them by sending requests to these endpoints with a range of starting characters)
API.add 'service/jct/suggest', get: () -> return API.service.jct.suggest this.queryParams.which, this.queryParams.q, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which', get: () -> return API.service.jct.suggest this.urlParams.which, undefined, this.queryParams.from, this.queryParams.size
API.add 'service/jct/suggest/:which/:ac', get: () -> return API.service.jct.suggest this.urlParams.which, this.urlParams.ac, this.queryParams.from, this.queryParams.size

API.add 'service/jct/compliance', () -> return jct_compliance.search this
API.add 'service/jct/journal', () -> return academic_journal.search this # should journals be restricted to only those of the 200 publishers plan S wish to focus on?
API.add 'service/jct/funder', get: () -> return API.service.jct.funders undefined, this.queryParams.refresh
API.add 'service/jct/institution', get: () -> return [] # return a total list of all the institutions we know? Any more use than the suggest route?
API.add 'service/jct/publisher', get: () -> return API.service.jct._publishers
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
API.add 'service/jct/ta/agreements', 
  csv: true
  get: () -> return jct_agreement.fetch() # check it is possible for the system to fetch all, otherwise batch and fetch them in a more efficient way
API.add 'service/jct/ta/esac', # convenience for getting esac data from their web page, but not actually our direct source of TA data
  csv: true
  get: () -> return API.service.jct.ta.esac undefined, this.queryParams.refresh
API.add 'service/jct/ta/import', get: () -> return API.service.jct.ta.import()

API.add 'service/jct/tj', # allow dump of all TJ?
  csv: true
  get: () -> return API.service.jct.tj this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/tj/:issn', get: () -> return API.service.jct.tj this.urlParams.issn #, this.queryParams.issn

API.add 'service/jct/doaj', 
  csv: true
  get: () -> return API.service.jct.doaj this.queryParams.issn, this.queryParams.refresh
API.add 'service/jct/doaj/:issn', get: () -> return API.service.jct.doaj this.urlParams.issn #, this.queryParams.refresh

API.add 'service/jct/permission', get: () -> return API.service.jct.permission this.queryParams.issn
API.add 'service/jct/permission/:issn', get: () -> return API.service.jct.permission this.urlParams.issn

API.add 'service/jct/retention', get: () -> return API.service.jct.retention this.queryParams.issn
API.add 'service/jct/retention/:issn', get: () -> return API.service.jct.retention this.urlParams.issn

API.add 'service/jct/feedback',
  get: () -> return API.service.jct.feedback this.queryParams
  post: () -> return API.service.jct.feedback this.bodyParams



API.service.jct.feedback = (params={}) ->
  if typeof params.name is 'string' and typeof params.email is 'string' and typeof params.feedback is 'string' and (not params.context? or typeof params.context is 'object')
    API.mail.send
      from: 'nobody@cottagelabs.com'
      to: 'jct@cottagelabs.com'
      subject: 'JCT system feedback'
      text: JSON.stringify params, '', 2
    return true
  else
    return false



API.service.jct.suggest = (which='journal', q, from, size) ->
  if which is 'funder'
    res = []
    if q
      q = q.toLowerCase()
      for f in API.service.jct.funders()
        if f.funder.toLowerCase().indexOf(q) isnt -1
          res.push title: f.funder, id: f.id
    else
      res = API.service.jct.funders()
    return total: res.length, data: res
  else
    # TODO restrict to journals by the plan s top 200 publishers? and what institutions? 
    # if journal search finds nothing, try a "topic" search using some of the search terms
    # against keywords, subjects, and "topics" on the journals
    return API.service.academic[which].suggest q, from, size



# check to see if we already know if a given set of entities is compliant
# and if so, check if that compliance is still valid now
API.service.jct.compliance = (funder, journal, institution, refresh=86400000) ->
  # funder # funder has no effect on decision at the moment, so can re-use any compliance that matches the other one or two
  qr = if journal then 'issn.exact:"' + journal + '"' else ''
  if institution
    qr += ' AND ' if qr isnt ''
    qr += 'ror.exact:"' + institution + '"'
  if qr isnt ''
    qr += ' AND NOT cache:true AND createdAt:>' + Date.now() - refresh
    # get the most recent non-cached calculated compliance for this set of entities
    pre = jct_compliance.find qr
    # if there are any results, or a calculation returned no results within 1 day (default), re-use it if possible
    if pre?
      if not pre.results? or not pre.results.length
        return pre # return the empty result set?
      else
        nr = []
        for r in pre.results
          # TODO this is in progress
          # if fully compliant by DOAJ or OAB, re-use it
          # if compliant by TJ, check if still in TJ - if not, remove it
          # if compliant by TA, check the "until" dates on the TJ qualifications - if too old, remove it
          delete r.started
          delete r.ended
          delete r.took
          r.cache = true
          nr.push r
        pre.results = nr
        return pre
  else
    return undefined


  
API.service.jct.calculate = (params={}, refresh, checks=['permission', 'doaj', 'ta', 'tj']) ->
  # given funder(s), journal(s), institution(s), find out if compliant or not
  # note could be given lists of each - if so, calculate all and return a list
  rq = Random.id() # random ID to store with the cached results, to measure number of unique requests that aggregate multiple sets of entities
  started = Date.now()
  if params.issn
    params.journal = params.issn
    delete params.issn
  if params.ror
    params.institution = params.ror
    delete params.ror
  for p in ['funder','journal','institution']
    params[p] = params[p].toString() if typeof params[p] is 'number'
    params[p] = params[p].split(',') if typeof params[p] is 'string' and params[p].indexOf(',') isnt -1
    params[p] = [params[p]] if typeof params[p] is 'string'
    params[p] ?= []
  results = []
  checked = 0
  _check = (funder, journal, institution) ->
    _results = []
    cr = permission: ('permission' in checks), doaj: ('doaj' in checks), ta: ('ta' in checks), tj: ('tj' in checks)

    # look for cached results for the same values in jct_compliance - if found, use them (with suitable cache-busting params)
    pre = if refresh in [true,0] then undefined else API.service.jct.compliance funder, journal, institution, refresh
    if pre?.results?
      _results = pre.results

    # which ones need re-checked if already found in cache? any? all?
    _ck = (which) ->
      Meteor.setTimeout () ->
        try
          if rs = API.service.jct[which] journal, institution
            _results.push(r) for r in (if _.isArray(rs) then rs else [rs])
          cr[which] = Date.now()
        catch
          cr[which] = false
      , 1
    _ck(c) for c in checks

    while cr.permission is true or cr.doaj is true or cr.ta is true or cr.tj is true
      future = new Future()
      Meteor.setTimeout (() -> future.return()), 100
      future.wait()
    # store a new set of results every time without removing old ones, to keep track of incoming request amounts
    #jct_compliance.insert journal: journal, funder: funder, institution: institution, rq: rq, cache: (if pre? then true else false), results: _results
    results.push(rs) for rs in _results

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
  _prl(c) for c in combos
  while checked isnt combos.length
    future = new Future()
    Meteor.setTimeout (() -> future.return()), 100
    future.wait()

  ended = Date.now()
  compliant = false
  for rc in results
    if rc.compliant is 'yes'
      compliant = true
      break
  return
    request:
      started: started
      ended: ended
      took: ended-started
      issn: params.journal
      funder: params.funder
      ror: params.institution
    compliant: compliant
    results: results



# For a TA to be in force, the ISSN and the ROR mus be found, and the current 
# date must be after journal start date and institution start date, and before 
# journal end date and institution end date - a journal and institution could 
# also be in more than one TA at a time
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
    log: [{action: 'Check transformative agreements for currently active agreement between journal and institution'}]
  at ?= res.started
  # what if start or end dates do not exist, but at least one of them does? Must they all exist?
  qr = 'journalStartAt:<' + at + ' AND institutionStartAt:<' + at + ' AND journalEndAt:>' + at + ' AND institutionEndAt:>' + at
  qr += ' AND issn.exact:"' + issn + '"' if issn 
  qr += ' AND ror.exact:"' + ror + '"' if ror
  jct_agreement.each qr, (rec) ->
    rs = _.clone res
    rs.compliant = 'yes'
    rs.qualifications = if ta.corresponding_authors then [{corresponding_authors: {}}] else []
    rs.until = ta['Journal End Date'] # ta['Institution End Date'] should be earliest of these
    rs.log[0].result = 'A currently active transformative agreement between the journal and institution was found'
    rs.ended = Date.now()
    rs.took = res.ended-res.started
    tas.push rs
  if tas.length is 0
    res.compliant = 'no'
    res.log[0].result = 'There are no transformative agreements between the journal and institution'
    res.ended = Date.now()
    res.took = res.ended-res.started
    tas.push res
  return if tas.length is 1 then tas[0] else tas

API.service.jct.ta._esac = false
API.service.jct.ta.esac = (id,refresh) ->
  res = []
  if API.service.jct.ta._esac isnt false and refresh isnt true
    res = API.service.jct.ta._esac
  else
    for r in API.convert.table2json API.http.puppeteer 'https://esac-initiative.org/about/transformative-agreements/agreement-registry/'
      rec =
        publisher: r.Publisher.trim()
        country: r.Country.trim()
        customer: r.Customer.trim()
        size: r["Size (# annual publications)"].trim()
        start_date: r["Start Date"].trim()
        end_date: r["End Date"].trim()
        id: r["Details/ ID"].trim()
      rec.url = 'https://esac-initiative.org/about/transformative-agreements/agreement-registry/' + rec.id
      rec.startAt = moment(rec.start_date, 'MM/DD/YYYY').valueOf()
      rec.endAt = moment(rec.end_date, 'MM/DD/YYYY').valueOf()
      try
        rs = parseInt rec.size
        if typeof rs is 'number' and not isNaN rs
          rec.size = sz
      res.push rec
    API.service.jct.ta._esac = res

  if id?
    res = undefined
    for e in res
      res = e if e.id is id
  return res

# import transformative agreements data from sheets, which should indicate if the agreement 
# is valid and active between which dates, and for which institutions
# see https://github.com/antleaf/jct-project/blob/master/api/ta.md
# for spec on how sheets will contain our TA data
# get this csv https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=0&single=true&output=csv
# for each item that says "ready" in "Status", get the "Data URL" - if it's a valid URL, get the csv from it
# which will contain
# Journal Name	ISSN (Print)	ISSN (Online)	Journal Start Date	Journal End Date	Intitution Name	ROR ID	Institution Start Date	Institution End Date
# Journal 1	0000-0000		2020-10-01	2022-02-01	Inst 1	abc	2020-08-22	
API.service.jct.ta.import = () ->
  API.service.jct.ta.esac undefined, true
  records = []
  res = sheets: 0, ready: 0, records: 0
  for ov in API.convert.csv2json 'https://docs.google.com/spreadsheets/d/e/2PACX-1vStezELi7qnKcyE8OiO2OYx2kqQDOnNsDX1JfAsK487n2uB_Dve5iDTwhUFfJ7eFPDhEjkfhXhqVTGw/pub?gid=0&single=true&output=csv'
    res.sheets += 1
    if ov.Status?.toLowerCase().trim() is 'ready' and typeof ov?['Data URL'] is 'string' and ov['Data URL'].trim().indexOf('http') is 0
      res.ready += 1
      src = ov['Data URL'].trim()
      for rec in API.convert.csv2json src
        res.records += 1
        for k of ov
          rec[k] = ov[k]
        rec.issn = []
        for ik in ['ISSN (Print)','ISSN (Online)']
          for isp in rec[ik].split ','
            isp = isp.trim()
            rec.issn.push(isp) if isp.length and isp not in rec.issn
        for d in ['Journal Start Date','Journal End Date','Institution Start Date','Institution End Date']
          if rec[d]? and rec[d].length
            dr = d.toLowerCase().replace(/ /g,'').replace('start','Start').replace('end','End').replace('date','At')
            rec[d] = rec[d].trim()
            rec[dr] = moment(rec[d], 'YYYY-MM-DD').valueOf() if rec[d].length
        rec.journal = rec['Journal Name'].trim() if rec['Journal Name']?
        rec.institution = rec['Institution Name'].trim() if rec['Institution Name']
        rec.ror = rec['ROR ID'].trim() if rec['ROR ID']?
        rec.corresponding_authors = true if rec['C/A Only'].trim().toLowerCase() is 'yes'
        records.push rec
  jct_agreement.remove '*'
  loaded = jct_agreement.insert records
  try res.loaded = loaded.responses[0].data.items.length
  res.extracted = records.length
  return res



# import transformative journals data, which should indicate if the journal IS 
# transformative or just in the list for tracking (to be transformative means to 
# have submitted to the list with the appropriate responses)
# fields called pissn and eissn will contain ISSNs to check against

# check if an issn is in the transformative journals list (to be provided by plan S)
API.service.jct.tj = (issn, refresh=86400000) -> # refresh each day?
  # this will be developed further once it is decided where the data will come from
  if issn
    res = 
      started: Date.now()
      ended: undefined
      took: undefined
      route: 'tj'
      compliant: 'unknown' # how could this ever be unknown? Better to make it true/false?
      qualifications: undefined
      issn: issn
      log: [{action: 'Check transformative journals list for journal'}]
    if issn in API.service.jct._tj
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
    return API.service.jct._tj



# what are these qualifications relevant to? TAs?
#rights_retention_author_advice - 
#rights_rentention_funder_implementation - the journal does not have an SA policy and the funder has a rights retention policy that starts in the future. There should be one record of this per funder that meets the conditions, and the following qualification specific data is requried:
#funder: <funder name>
#date: <date policy comes into force (YYYY-MM-DD)
API.service.jct.retention = (journal) ->
  # check the rights retention data source once it exists if the record is not in OAB
  # for now this is not used directly, just a fallback to something that is not in OAB
  # will be a list of journals by ISSN and a number 1,2,3,4,5
  # import them if not yet present (and probably do some caching)
  rets = []
  if journal
    res =
      started: Date.now()
      ended: undefined
      took: undefined
      route: 'retention' # this is actually only used as a subset of OAB permission self_archiving so far
      compliant: 'yes' # if not present then compliant but with author and funder quals - so what are the default funder quals?
      qualifications: [{'rights_retention_author_advice': 'The journal does not appear in the rights retention data source'}]
      issn: journal
      log: [{action: 'Check for author rights retention', result: 'Rights retention not found, so default compliant'}]
    for ret in rets
      if ret.issn is journal
        if ret.number is 5 # if present and 5, not compliant
          res.log[0].result = 'Rights retention number ' + ret.number + ' so not compliant'
          res.compliant = 'no'
          delete res.qualifications
        else
          res.log[0].result = 'Rights retention number ' + ret.number + ' so compliant'
          # if present and any other number, or no answer, then compliant with some funder quals - so what funder quals to add?
        break
    res.ended = Date.now()
    res.took = res.ended-res.started
    return res
  else
    return rets



API.service.jct.permission = (journal) ->
  res =
    started: Date.now()
    ended: undefined
    took: undefined
    route: 'self_archiving'
    compliant: 'unknown'
    qualifications: undefined
    issn: journal
    log: [{action: 'Check Open Access Button Permissions for journal'}]

  perms = API.service.oab.p2 journal
  if perms.best_permission?
    res.compliant = 'no' # set to no until a successful route through is found
    pb = perms.best_permission
    res.log[0].result = if pb.issuer.type is 'journal' then 'The journal is in OAB Permissions' else 'The publisher of the journal is in OAB Permissions'
    res.log.push {action: 'Check if OAB Permissions says the journal allows archiving'}
    if pb.can_archive
      res.log[1].result = 'OAB Permissions confirms the journal allows archiving'
      res.log.push {action: 'Check if postprint or publisher PDF can be archived'}
      if 'postprint' in pb.versions or 'publisher pdf' in pb.versions
        res.log[2].result = (if 'postprint' in pb.version then 'Postprint' else 'Publisher PDF') + ' can be archived'
        res.log.push {action: 'Check there is no embargo period'}
        # and Embargo is zero
        if not res.embargo_end
          res.log[3].result = 'There is no embargo period'
          res.log.push {action: 'Check there is a suitable licence'}
          lc = false
          for l in res.licences ? []
            if l.type.toLowerCase().replace(/\-/g,'').replace(/ /g,'') in ['ccby','ccbysa','cc0','ccbynd']
              lc = l.type
              break
          if lc
            res.log[4].result = 'There is a suitable ' + lc + ' licence'
          else
            res.log[4].result = 'No suitable licence found'
        else
          res.log[3].result = 'There is an embargo until ' + res.embargo_end
      else
        res.log[2].result = 'It is not possible to archive postprint or publisher PDF'
    else
      res.log[1].result = 'OAB Permissions states that the journal does not allow archiving'
    # is there any useful URL that permissions could link back to?
  else
    res.log[0].result = 'The journal was not found in OAB Permissions'
    # does this mean unknown or no?

  res.ended = Date.now()
  res.took = res.ended-res.started
  #if res.compliant isnt 'yes' 
  #  # if OAB said no, does retention override that? Or only check this if OAB is unknown?
  #  res = [res]
  #  res.push API.service.jct.retention journal # use this as an override or return two?
  return res



# import doaj data including applications in progress, to find journals in  or soon to be in it
API.service.jct.doaj = (issn, refresh=86400000) -> # refresh each day
  # adding this here rather than in DOAJ service user because this part of DOAJ 
  # API exists exclusively for JCT. Can move later if suitable
  # add a cache to this with a suitable refresh
  progs = []
  if refresh isnt true and refresh isnt 0 and cached = API.http.cache 'din', 'doaj_in_progress', undefined, refresh
    progs = cached
  else
    try
      r = HTTP.call 'GET', 'https://doaj.org/jct/inprogress?api_key=' + API.settings.service.jct.doaj.apikey
      rc = JSON.parse r.content
      API.http.cache 'din', 'doaj_in_progress', rc
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
        if true # if an application, has to have applied within X months (probably 4 - where will the application date be?)
          res.log[1].result = 'Application to DOAJ is still current, being X months old'
          res.compliant = 'yes'
          res.qualifications = [{doaj_under_review: {}}]
        else
          res.log[1].result = 'Application is too old, so the journal is not a valid route'
          res.compliant = 'no'

    # if there wasn't an application, continue to check DOAJ itself
    if res.compliant is 'unknown'
      res.log.push {action: 'Check if the journal is currently in the DOAJ'}
      if db = academic_journal.find 'issn.exact:"' + issn + '" AND src.exact:"doaj"'
        res.log[1].result = 'The journal has been found in DOAJ'
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
          # Preservation	bibjson.archiving_policy.policy[].name	bibjson.preservation.has_preservation:true
          if not db.archiving_policy? and not db.preservation?.has_preservation?
            res.log[3].result = 'Archiving preservation policy data is missing, compliance cannot be calculated'
            missing.push 'preservation.has_preservation'
          else if (db.archiving_policy? and db.archiving_policy.length and db.archiving_policy[0].name?) or db.preservation?.has_preservation is true
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
                    res.log[7].result = 'The journal has a suitable licence: ' + bl
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
                      res.log[8].result = 'The journal does have an embedded licence'
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
          res.compliant = 'no'
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
API.service.jct._funders = false
API.service.jct.funders = (id,refresh) ->
  res = []
  if API.service.jct._funders isnt false and refresh isnt true
    res = API.service.jct._funders
  else
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
      if rec.retention and rec.retention.indexOf('Note:') isnt -1
        rec.notes ?= []
        rec.notes.push rec.retention.split('Note:')[1].replace(')','').trim()
        rec.retention = rec.retention.split('Note:')[0].replace('(','').trim()
      try rec.startAt = moment(rec.launch, 'Do MMMM YYYY').valueOf()
      delete rec.startAt if JSON.stringify(rec.startAt) is 'null'
      if not rec.startAt? and rec.launch?
        rec.notes ?= []
        rec.notes.push rec.launch
      try rec.id = rec.funder.toLowerCase().replace(/[^a-z0-9]/g,'')
      res.push(rec) if rec.id?
    API.service.jct._funders = res

  if id?
    res = undefined
    for e in res
      res = e if e.id is id
  return res


  
API.service.jct.import = (params) ->
  # run all imports necessary for up to date data
  if not params? or _.isEmpty params
    params = retention: true, funders: true, journals: true, doaj: true, ta: true #, tj: true
  res = {}
  if false #params.journals
    res.journals = API.service.academic.journal.load ['doaj'] # or a new load of all journals? what about source files?
  if params.doaj
    res.doaj = API.service.jct.doaj undefined, true
  if params.ta
    res.ta = API.service.jct.ta.import()
  if params.retention
    res.retention = API.service.jct.retention()
  if params.funders
    API.service.jct.funders undefined, true
  # institution lists?
  # anything in OAB to trigger?
  API.mail.send
    from: 'nobody@cottagelabs.com'
    to: 'jct@cottagelabs.com'
    subject: 'JCT import complete'
    text: JSON.stringify res, '', 2
  return res
  
# create an import cron if necessary, or use noddy job runner if more appropriate
# may also cron a list of pings via cloudflare to preload it

# create any specific test endpoints that are required, but ideally use the difference tester
# service to automatically test endpoints whenever code is pushed, or on whatever schedule is necessary
# expected test results:
# https://docs.google.com/document/d/1AZX_m8EAlnqnGWUYDjKmUsaIxnUh3EOuut9kZKO3d78/edit




API.service.jct._tj = [] # this may become a remote source

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