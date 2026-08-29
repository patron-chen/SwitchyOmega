chai = require('chai')
expect = chai.expect

Match = require('../src/module/proxy_environment_match')

describe 'ProxyEnvironmentManager', ->
  fixed = {name: 'proxy', profileType: 'FixedProfile'}
  pac = {name: 'pac', profileType: 'PacProfile'}
  direct = {name: 'direct', profileType: 'DirectProfile'}
  system = {name: 'system', profileType: 'SystemProfile'}
  switchProfile = {name: 'auto', profileType: 'SwitchProfile'}

  explicit = (profileName = 'proxy') ->
    {profileName: profileName, condition: {conditionType: 'HostCondition'}}

  it 'enables an explicitly matched fixed profile', ->
    match = {profile: fixed, results: [explicit(), ['PROXY host:80', '', {}]]}
    expect(Match.shouldEnableForMatch(match)).to.equal(true)

  it 'enables an explicitly matched PAC profile', ->
    match = {profile: pac, results: [explicit('pac')]}
    expect(Match.shouldEnableForMatch(match)).to.equal(true)

  it 'enables a manually selected fixed proxy profile', ->
    match = {profile: fixed, results: [['PROXY host:80', '', {}]]}
    expect(Match.shouldEnableForMatch(match, fixed)).to.equal(true)

  it 'enables a manually selected PAC profile', ->
    match = {profile: pac, results: []}
    expect(Match.shouldEnableForMatch(match, pac)).to.equal(true)

  it 'disables direct and system results', ->
    directMatch = {profile: direct, results: [explicit('direct')]}
    systemMatch = {profile: system, results: [explicit('system')]}
    expect(Match.shouldEnableForMatch(directMatch))
      .to.equal(false)
    expect(Match.shouldEnableForMatch(systemMatch))
      .to.equal(false)

  it 'does not treat a default profile as an explicit match', ->
    match = {profile: fixed, results: [['+proxy', null], ['PROXY host:80']]}
    expect(Match.shouldEnableForMatch(match, switchProfile)).to.equal(false)

  it 'does not enable manually selected direct or system profiles', ->
    directMatch = {profile: direct, results: []}
    systemMatch = {profile: system, results: []}
    expect(Match.shouldEnableForMatch(directMatch, direct)).to.equal(false)
    expect(Match.shouldEnableForMatch(systemMatch, system)).to.equal(false)

  it 'keeps an outer explicit match across nested defaults', ->
    match = {
      profile: fixed
      results: [explicit('nested'), ['+proxy', null], ['PROXY host:80', '']]
    }
    expect(Match.shouldEnableForMatch(match)).to.equal(true)

  it 'fails closed when a referenced profile is missing', ->
    match =
      profile: {name: 'switch', profileType: 'SwitchProfile'}
      results: [explicit('missing')]
    expect(Match.shouldEnableForMatch(match)).to.equal(false)

  it 'fails closed when a default target is missing', ->
    match =
      profile: {name: 'switch', profileType: 'SwitchProfile'}
      results: [explicit('switch'), ['+missing', null]]
    expect(Match.shouldEnableForMatch(match)).to.equal(false)

  it 'builds an Accept-Language value from the configured locale', ->
    expect(Match.languageHeaderValue('en-US')).to.equal('en-US,en;q=0.9')
    expect(Match.languageHeaderValue('zh-CN')).to.equal('zh-CN,zh;q=0.9')
    expect(Match.languageHeaderValue('de')).to.equal('de')

  it 'builds a tab-scoped session header rule', ->
    rule = Match.buildLanguageHeaderRule(1500000000, 42, 'en-US')
    expect(rule.action.type).to.equal('modifyHeaders')
    expect(rule.action.requestHeaders[0]).to.deep.equal({
      header: 'Accept-Language'
      operation: 'set'
      value: 'en-US,en;q=0.9'
    })
    expect(rule.condition.tabIds).to.deep.equal([42])
    expect(rule.condition.urlFilter).to.equal('|http')

  it 'builds a global session header rule for manual proxy mode', ->
    rule = Match.buildLanguageHeaderRule(1499999999, null, 'zh-CN')
    expect(rule.condition.tabIds).to.equal(undefined)
    expect(rule.condition.urlFilter).to.equal('|http')
    expect(rule.action.requestHeaders[0].value).to.equal('zh-CN,zh;q=0.9')
