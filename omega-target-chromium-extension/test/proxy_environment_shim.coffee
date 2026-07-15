chai = require('chai')
expect = chai.expect
fs = require('fs')
path = require('path')
vm = require('vm')

mainSource = fs.readFileSync(path.join(__dirname,
  '../overlay/proxy-environment/main.js'), 'utf8')
isolatedSource = fs.readFileSync(path.join(__dirname,
  '../overlay/proxy-environment/isolated.js'), 'utf8')

class FakeElement
  constructor: ->
    @id = ''
    @style = {}
    @attributes = {}
    @listeners = {}

  setAttribute: (name, value) -> @attributes[name] = String(value)
  getAttribute: (name) -> @attributes[name] ? null
  addEventListener: (name, listener) -> @listeners[name] = listener
  dispatchEvent: (event) -> @listeners[event.type]?()

createDocument = ->
  port = null
  foreign = new FakeElement()
  foreign.id = 'zero-omega-proxy-environment-port'
  document =
    referrer: 'https://parent.example/frame'
    querySelector: (selector) ->
      if port?.getAttribute('data-zero-omega-proxy-environment-port') == 'v1'
        port
      else
        null
    createElement: -> new FakeElement()
    getElementById: -> foreign
    documentElement:
      appendChild: (element) -> port = element
  {document, foreign, getPort: -> port}

createMainWorld = ->
  dom = createDocument()
  Event = class Event
    constructor: (@type) -> null
  context = vm.createContext(
    document: dom.document
    navigator: {language: 'en-GB', languages: Object.freeze(['en-GB', 'en'])}
    Event: Event
    console: console
    setTimeout: setTimeout
    clearTimeout: clearTimeout
  )
  context.self = context
  vm.runInContext('this.nativeLanguages = navigator.languages', context)
  vm.runInContext(mainSource, context, filename: 'main.js')
  {context, dom}

setState = (world, enabled, timezone, language) ->
  timezone ?= 'America/New_York'
  language ?= 'fr-CA'
  port = world.dom.getPort()
  port.setAttribute('data-enabled', if enabled then 'true' else 'false')
  port.setAttribute('data-timezone', timezone)
  port.setAttribute('data-language', language)
  port.dispatchEvent(type: 'zero-omega-proxy-environment-change')

evaluate = (world, expression) ->
  vm.runInContext(expression, world.context)

describe 'proxy environment MAIN world shim', ->
  it 'preserves native behavior while disabled', ->
    world = createMainWorld()
    result = evaluate(world, '''
      ({
        name: Date.name,
        length: Date.length,
        callType: typeof Date(0),
        instance: new Date() instanceof Date,
        constructor: new Date().constructor === Date,
        functionPrototype: Object.getPrototypeOf(Date) === Function.prototype,
        subclass: new (class extends Date {})() instanceof Date,
        language: navigator.language,
        sameLanguages: navigator.languages === nativeLanguages,
        invalid: String(new Date(NaN))
      })
    ''')
    expect(result.name).to.equal('Date')
    expect(result.length).to.equal(7)
    expect(result.callType).to.equal('string')
    expect(result.instance).to.equal(true)
    expect(result.constructor).to.equal(true)
    expect(result.functionPrototype).to.equal(true)
    expect(result.subclass).to.equal(true)
    expect(result.language).to.equal('en-GB')
    expect(result.sameLanguages).to.equal(true)
    expect(result.invalid).to.equal('Invalid Date')

  it 'uses per-instant DST offsets and configured defaults', ->
    world = createMainWorld()
    setState(world, true)
    result = evaluate(world, '''
      ({
        januaryHour: new Date('2024-01-15T12:00:00Z').getHours(),
        januaryOffset: new Date('2024-01-15T12:00:00Z').getTimezoneOffset(),
        julyHour: new Date('2024-07-15T12:00:00Z').getHours(),
        julyOffset: new Date('2024-07-15T12:00:00Z').getTimezoneOffset(),
        timezone: new Intl.DateTimeFormat().resolvedOptions().timeZone,
        language: navigator.language,
        languages: Array.from(navigator.languages).join(','),
        locale: new Intl.NumberFormat().resolvedOptions().locale,
        explicitLocale: new Intl.NumberFormat('en-US').resolvedOptions().locale,
        explicitZone: new Intl.DateTimeFormat('en-US', {timeZone: 'UTC'})
          .resolvedOptions().timeZone,
        explicitDate: new Date('Mon, 15 Jan 2024 12:00:00 GMT').toISOString()
      })
    ''')
    expect(result.januaryHour).to.equal(7)
    expect(result.januaryOffset).to.equal(300)
    expect(result.julyHour).to.equal(8)
    expect(result.julyOffset).to.equal(240)
    expect(result.timezone).to.equal('America/New_York')
    expect(result.language).to.equal('fr-CA')
    expect(result.languages).to.equal('fr-CA,fr')
    expect(result.locale).to.equal('fr-CA')
    expect(result.explicitLocale).to.equal('en-US')
    expect(result.explicitZone).to.equal('UTC')
    expect(result.explicitDate).to.equal('2024-01-15T12:00:00.000Z')

  it 'preserves native errors for invalid Intl options', ->
    world = createMainWorld()
    setState(world, true)
    result = evaluate(world, '''
      (() => {
        try {
          new Intl.DateTimeFormat(undefined, null);
          return false;
        }
        catch (error) {
          return error instanceof TypeError;
        }
      })()
    ''')
    expect(result).to.equal(true)

  it 'applies the language default across supported Intl constructors', ->
    world = createMainWorld()
    setState(world, true)
    result = evaluate(world, '''
      (() => {
        const options = {
          DisplayNames: {type: 'language'},
          DurationFormat: {},
          RelativeTimeFormat: {},
          Segmenter: {}
        };
        const names = [
          'Collator', 'DateTimeFormat', 'DisplayNames', 'DurationFormat',
          'ListFormat', 'NumberFormat', 'PluralRules', 'RelativeTimeFormat',
          'Segmenter'
        ].filter(name => typeof Intl[name] === 'function');
        return {
          defaults: names.map(name =>
            new Intl[name](undefined, options[name]).resolvedOptions().locale),
          configured: names.map(name =>
            new Intl[name]('fr-CA', options[name]).resolvedOptions().locale),
          number: (1234.5).toLocaleString(),
          expectedNumber: new Intl.NumberFormat('fr-CA').format(1234.5),
          bigint: (1234n).toLocaleString(),
          expectedBigint: new Intl.NumberFormat('fr-CA').format(1234n)
        };
      })()
    ''')
    expect(result.defaults.join(',')).to.equal(result.configured.join(','))
    expect(result.number).to.equal(result.expectedNumber)
    expect(result.bigint).to.equal(result.expectedBigint)

  it 'handles DST gaps, invalid dates, and live disable', ->
    world = createMainWorld()
    setState(world, true)
    result = evaluate(world, '''
      (() => {
        const gap = new Date(2024, 2, 10, 2, 30);
        const recovered = new Date(NaN);
        recovered.setFullYear(2020);
        return {
          gapHour: gap.getHours(),
          gapMinute: gap.getMinutes(),
          recovered: recovered.toISOString(),
          invalid: String(new Date(NaN))
        };
      })()
    ''')
    expect(result.gapHour).to.equal(3)
    expect(result.gapMinute).to.equal(30)
    expect(result.recovered).to.equal('2020-01-01T05:00:00.000Z')
    expect(result.invalid).to.equal('Invalid Date')

    setState(world, false)
    result = evaluate(world, '''
      ({
        language: navigator.language,
        same: navigator.languages === nativeLanguages
      })
    ''')
    expect(result.language).to.equal('en-GB')
    expect(result.same).to.equal(true)

  it 'does not reuse a foreign element with the same id or require dataset', ->
    world = createMainWorld()
    expect(world.dom.getPort()).not.to.equal(world.dom.foreign)
    expect(world.dom.getPort().dataset).to.equal(undefined)
    expect(world.dom.foreign.attributes).to.deep.equal({})

describe 'proxy environment ISOLATED world bridge', ->
  it 'sends the document URL and referrer and applies the reply', ->
    dom = createDocument()
    sent = null
    messageListener = null
    context = vm.createContext(
      document: dom.document
      location: {href: 'about:blank'}
      Event: class Event
        constructor: (@type) -> null
      chrome:
        runtime:
          lastError: null
          onMessage:
            addListener: (listener) -> messageListener = listener
          sendMessage: (message, callback) ->
            sent = message
            callback(result: {
              enabled: true
              timezone: 'Etc/GMT'
              language: 'en-US'
            })
    )
    vm.runInContext(isolatedSource, context, filename: 'isolated.js')
    expect(sent.args[0].url).to.equal('about:blank')
    expect(sent.args[0].referrer).to.equal('https://parent.example/frame')
    expect(dom.getPort().getAttribute('data-enabled')).to.equal('true')

    messageListener(method: 'proxyEnvironment.update', state: {
      enabled: false
      timezone: 'Asia/Tokyo'
      language: 'ja-JP'
    })
    expect(dom.getPort().getAttribute('data-enabled')).to.equal('false')
    expect(dom.getPort().getAttribute('data-timezone')).to.equal('Asia/Tokyo')
