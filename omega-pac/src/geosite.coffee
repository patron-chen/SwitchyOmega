Data = require './geosite_data'
Builder = require './geosite_builder'

emptyList =
  plain: []
  regexp: []
  domain: []
  full: []
  attrs: {}

cloneList = (list, withAttrs = false) ->
  result =
    plain: (list?.plain ? []).slice()
    regexp: (list?.regexp ? []).slice()
    domain: (list?.domain ? []).slice()
    full: (list?.full ? []).slice()
  if withAttrs and list?.attrs
    result.attrs = {}
    for own attr, attrList of list.attrs
      result.attrs[attr] = cloneList(attrList)
  result

normalizeHost = (host) ->
  return '' unless host
  host = host.toLowerCase()
  if host.charCodeAt(0) == '['.charCodeAt(0)
    host = host.substr(1, host.length - 2)
  host

intersect = (left, right) ->
  value for value in left when right.indexOf(value) >= 0

normalizeAttr = (attr) ->
  if attr?[0] == '+' then attr.substr(1) else attr

listForParsed = (parsed, data = Data, missing = emptyList) ->
  return missing unless parsed.code
  group = data.groups?[parsed.code]
  return missing unless group
  if parsed.attrs.length == 0
    return group
  current = null
  for attr in parsed.attrs
    next = group.attrs?[normalizeAttr(attr)]
    return missing unless next
    if current?
      current =
        plain: intersect(current.plain, next.plain)
        regexp: intersect(current.regexp, next.regexp)
        domain: intersect(current.domain, next.domain)
        full: intersect(current.full, next.full)
    else
      current = next
  current ? missing

module.exports = exports =
  setData: (data) ->
    Data = data ? {version: 1, groups: {}}

  getData: -> Data

  buildData: Builder.buildData

  parseSpec: (spec) ->
    spec = (spec ? '').trim().toLowerCase()
    if spec.substr(0, 8) == 'geosite:'
      spec = spec.substr(8)
    parts = spec.split('@')
    code: parts.shift()
    attrs: (part for part in parts when part)
    raw: spec

  references: (pattern) ->
    parsed = exports.parseSpec(pattern)
    return [] unless parsed.code
    [parsed.raw]

  addReferences: (condition, out) ->
    return out unless condition?.conditionType == 'GeositeCondition'
    for ref in exports.references(condition.pattern)
      out[ref] = true
    out

  listForSpec: (spec, data = Data) ->
    parsed = exports.parseSpec(spec)
    listForParsed(parsed, data)

  matchList: (list, host) ->
    host = normalizeHost(host)
    return false unless host
    for value in list.full ? []
      return true if host == value
    for value in list.domain ? []
      return true if host == value
      return true if host.length > value.length and
        host.substr(host.length - value.length - 1) == '.' + value
    for value in list.plain ? []
      return true if host.indexOf(value) >= 0
    if list.regexp?.length
      unless list._regexp
        list._regexp = []
        for value in list.regexp
          try
            list._regexp.push new RegExp(value)
          catch _
            null
      for regexp in list._regexp
        return true if regexp?.test(host)
    false

  match: (spec, host) ->
    exports.matchList(exports.listForSpec(spec), host)

  dataFor: (refs, data = Data) ->
    result =
      version: 1
      groups: {}
    for ref in refs
      parsed = exports.parseSpec(ref)
      continue unless parsed.code
      source = listForParsed(parsed, data, null)
      continue unless source?
      copied = cloneList(source)
      result.groups[parsed.raw] =
        plain: copied.plain
        regexp: copied.regexp
        domain: copied.domain
        full: copied.full
        attrs: {}
    result

  pacMatcherSource: ->
    '''
    function __omega_geosite_match_list(host, group) {
      var i, value, regexp, list = group.full || [];
      for (i = 0; i < list.length; i++) if (host === list[i]) return true;
      list = group.domain || [];
      for (i = 0; i < list.length; i++) {
        value = list[i];
      if (host === value ||
          host.substr(host.length - value.length - 1) === "." + value) {
        return true;
      }
      }
      list = group.plain || [];
      for (i = 0; i < list.length; i++) {
        if (host.indexOf(list[i]) >= 0) return true;
      }
      list = group.regexp || [];
      if (!group._regexp) {
        group._regexp = [];
        for (i = 0; i < list.length; i++) {
          try { group._regexp.push(new RegExp(list[i])); } catch (_) {}
        }
      }
      for (i = 0; i < group._regexp.length; i++) {
        if (group._regexp[i].test(host)) return true;
      }
      return false;
    }
    function __omega_geosite_match(host, spec) {
      host = (host || "").toLowerCase();
      if (host.charCodeAt(0) === 91) host = host.substr(1, host.length - 2);
      spec = (spec || "").replace(/^\\s+|\\s+$/g, "").toLowerCase();
      if (spec.substr(0, 8) === "geosite:") spec = spec.substr(8);
      var group = __omega_geosite_data.groups[spec];
      if (group) return __omega_geosite_match_list(host, group);
      var parts = spec.split("@");
      group = __omega_geosite_data.groups[parts.shift()];
      if (!group) return false;
      if (parts.length === 0) {
        return __omega_geosite_match_list(host, group);
      }
      for (var p = 0; p < parts.length; p++) {
        var attr = parts[p];
        if (attr.charCodeAt(0) === 43) attr = attr.substr(1);
        var attrGroup = group.attrs && group.attrs[attr];
        if (!attrGroup ||
            !__omega_geosite_match_list(host, attrGroup)) {
          return false;
        }
      }
      return true;
    }
    '''

  pacSourceFor: (refs, data = Data) ->
    data = exports.dataFor(refs, data)
    'var __omega_geosite_data=' + JSON.stringify(data) + ';\n' +
      exports.pacMatcherSource()
