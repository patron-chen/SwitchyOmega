TYPES = ['plain', 'regexp', 'domain', 'full']

toBytes = (buffer) ->
  return buffer if buffer instanceof Uint8Array
  return new Uint8Array(buffer) if buffer instanceof ArrayBuffer
  if buffer?.buffer?
    return new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength)
  throw new Error('Unsupported geosite data buffer')

decodeUtf8 = (bytes) ->
  if typeof TextDecoder != 'undefined'
    return new TextDecoder('utf-8').decode(bytes)
  if typeof Buffer != 'undefined'
    return Buffer.from(bytes).toString('utf8')
  text = ''
  for byte in bytes
    text += String.fromCharCode(byte)
  decodeURIComponent(escape(text))

class Reader
  constructor: (buffer) ->
    @buffer = toBytes(buffer)
    @pos = 0
    @end = @buffer.length

  done: -> @pos >= @end

  varint: ->
    shift = 0
    value = 0
    while @pos < @end
      byte = @buffer[@pos++]
      value += (byte & 0x7f) * Math.pow(2, shift)
      return value if (byte & 0x80) == 0
      shift += 7
    throw new Error('Unexpected end while reading varint')

  bytes: ->
    length = @varint()
    start = @pos
    end = start + length
    throw new Error('Length-delimited field exceeds buffer') if end > @end
    @pos = end
    @buffer.slice(start, end)

  string: -> decodeUtf8(@bytes())

  skip: (wireType) ->
    switch wireType
      when 0
        @varint()
      when 1
        @pos += 8
      when 2
        @bytes()
      when 5
        @pos += 4
      else
        throw new Error('Unsupported protobuf wire type: ' + wireType)
    throw new Error('Skipped past end of buffer') if @pos > @end

decodeAttribute = (buffer) ->
  reader = new Reader(buffer)
  attr = {key: '', boolValue: true}
  until reader.done()
    tag = reader.varint()
    field = Math.floor(tag / 8)
    wireType = tag & 7
    if field == 1 and wireType == 2
      attr.key = reader.string().toLowerCase()
    else if field == 2 and wireType == 0
      attr.boolValue = !!reader.varint()
    else
      reader.skip(wireType)
  attr

decodeDomain = (buffer) ->
  reader = new Reader(buffer)
  domain = {type: 0, value: '', attrs: []}
  until reader.done()
    tag = reader.varint()
    field = Math.floor(tag / 8)
    wireType = tag & 7
    if field == 1 and wireType == 0
      domain.type = reader.varint()
    else if field == 2 and wireType == 2
      domain.value = reader.string().toLowerCase()
    else if field == 3 and wireType == 2
      attr = decodeAttribute(reader.bytes())
      domain.attrs.push(attr.key) if attr.key and attr.boolValue != false
    else
      reader.skip(wireType)
  domain

decodeGeoSite = (buffer) ->
  reader = new Reader(buffer)
  site = {code: '', domains: []}
  until reader.done()
    tag = reader.varint()
    field = Math.floor(tag / 8)
    wireType = tag & 7
    if field == 1 and wireType == 2
      site.code = reader.string().toLowerCase()
    else if field == 2 and wireType == 2
      site.domains.push decodeDomain(reader.bytes())
    else
      reader.skip(wireType)
  site

decodeGeoSiteList = (buffer) ->
  reader = new Reader(buffer)
  sites = []
  until reader.done()
    tag = reader.varint()
    field = Math.floor(tag / 8)
    wireType = tag & 7
    if field == 1 and wireType == 2
      sites.push decodeGeoSite(reader.bytes())
    else
      reader.skip(wireType)
  sites

emptyGroup = ->
  plain: []
  regexp: []
  domain: []
  full: []
  attrs: {}

addValue = (group, type, value) ->
  bucket = TYPES[type]
  return unless bucket and value
  group[bucket].push value

uniqueSorted = (list) ->
  seen = {}
  result = []
  for value in list
    continue if seen[value]
    seen[value] = true
    result.push value
  result.sort()

normalizeGroup = (group) ->
  for bucket in TYPES
    group[bucket] = uniqueSorted(group[bucket])
  attrs = {}
  for attr in Object.keys(group.attrs).sort()
    attrs[attr] = normalizeGroup(group.attrs[attr])
  group.attrs = attrs
  group

module.exports =
  decodeGeoSiteList: decodeGeoSiteList

  buildData: (buffer) ->
    groups = {}
    for site in decodeGeoSiteList(buffer)
      continue unless site.code
      group = groups[site.code] ?= emptyGroup()
      for domain in site.domains
        addValue(group, domain.type, domain.value)
        for attr in domain.attrs
          attrGroup = group.attrs[attr] ?= emptyGroup()
          addValue(attrGroup, domain.type, domain.value)
    sortedGroups = {}
    for code in Object.keys(groups).sort()
      sortedGroups[code] = normalizeGroup(groups[code])
    version: 1
    groups: sortedGroups
