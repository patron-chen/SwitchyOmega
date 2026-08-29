OmegaTarget = require('omega-target')
OmegaPac = OmegaTarget.OmegaPac
Promise = OmegaTarget.Promise
Match = require('./proxy_environment_match')

ISOLATED_SCRIPT_ID = 'zero-omega-proxy-environment-isolated'
MAIN_SCRIPT_ID = 'zero-omega-proxy-environment-main'
SCRIPT_IDS = [ISOLATED_SCRIPT_ID, MAIN_SCRIPT_ID]
ENVIRONMENT_OPTION_KEYS = [
  '-proxyEnvironmentEnabled'
  '-proxyEnvironmentTimezone'
  '-proxyEnvironmentLanguage'
]
GLOBAL_HEADER_RULE_ID = 1499999999
HEADER_RULE_ID_MIN = 1500000000
HEADER_RULE_ID_MAX = 1500004999

class ProxyEnvironmentManager
  @hasExplicitRuleMatch: Match.hasExplicitRuleMatch
  @isProxyProfile: Match.isProxyProfile
  @isManualProxyProfile: Match.isManualProxyProfile
  @isResolvedMatch: Match.isResolvedMatch
  @shouldEnableForMatch: Match.shouldEnableForMatch

  constructor: (@options, @log) ->
    @_frameStates = {}
    @_frameParents = {}
    @_frameUrls = {}
    @_refreshTimer = null
    @_watchStop = null
    @_lastResolveErrorAt = 0
    @_headerRulesByTab = {}
    @_headerRuleIds = {}
    @_nextHeaderRuleId = HEADER_RULE_ID_MIN
    @_globalHeaderRule = null
    @_headerRuleQueue = Promise.resolve()
    @_headerRuleReady = Promise.resolve()

  supported: ->
    not globalThis.localStorage and
      chrome?.scripting?.registerContentScripts? and chrome?.webNavigation?

  init: ->
    return Promise.resolve(false) unless @supported()

    chrome.webNavigation.onBeforeNavigate.addListener(
      @onBeforeNavigate.bind(this))
    chrome.webNavigation.onCommitted.addListener(@onCommitted.bind(this))
    chrome.webNavigation.onHistoryStateUpdated?.addListener(
      @onHistoryStateUpdated.bind(this))
    chrome.tabs.onRemoved.addListener(@onTabRemoved.bind(this))

    @_watchStop = @options.watch (changes) =>
      return unless @_changesAffectEnvironment(changes)
      @scheduleRefreshAll()

    @_headerRuleReady = @_restoreHeaderRules()
    @options.ready.then(=> Promise.all([
      @registerScripts()
      @_headerRuleReady
    ])).then(=>
      @scheduleRefreshAll()
      true
    ).catch((error) =>
      @log.error('Failed to initialize proxy environment scripts', error)
      false
    )

  registerScripts: ->
    chrome.scripting.getRegisteredContentScripts(ids: SCRIPT_IDS).then(
      (registered) ->
        return false if registered.length == SCRIPT_IDS.length
        chrome.scripting.unregisterContentScripts(ids: SCRIPT_IDS)
          .catch(-> null)
    ).then (register) ->
      return false if register == false
      chrome.scripting.registerContentScripts [
        {
          id: ISOLATED_SCRIPT_ID
          world: 'ISOLATED'
          matches: ['*://*/*']
          matchOriginAsFallback: true
          allFrames: true
          runAt: 'document_start'
          persistAcrossSessions: true
          js: ['proxy-environment/isolated.js']
        }
        {
          id: MAIN_SCRIPT_ID
          world: 'MAIN'
          matches: ['*://*/*']
          matchOriginAsFallback: true
          allFrames: true
          runAt: 'document_start'
          persistAcrossSessions: true
          js: ['proxy-environment/main.js']
        }
      ]

  getForSender: (sender, details = {}) ->
    tabId = sender?.tab?.id
    frameId = sender?.frameId ? 0
    url = details.url ? sender?.url ? ''
    @_beginFrame({tabId, frameId, url}) if tabId?

    if @_isMatchableUrl(url)
      key = @_frameKey(tabId, frameId) if tabId?
      if key? and @_frameUrls[key] == url and @_frameStates[key]?
        return Promise.resolve(@_frameStates[key])
      return @resolve(url).then (state) =>
        @_remember(tabId, frameId, state, url) if tabId?
        state

    state = @_frameStates[@_frameKey(tabId, frameId)] if tabId?
    unless state? or not tabId?
      parentFrameId = @_frameParents[@_frameKey(tabId, frameId)]
      if parentFrameId? and parentFrameId >= 0
        state = @_frameStates[@_frameKey(tabId, parentFrameId)]
    return Promise.resolve(state) if state?

    if @_isMatchableUrl(details.referrer)
      return @resolve(details.referrer).then (state) =>
        @_remember(tabId, frameId, state, url) if tabId?
        state

    state ?= @_frameStates[@_frameKey(tabId, 0)] if tabId?
    Promise.resolve(state ? @_disabledState('opaque-url'))

  resolve: (url) ->
    @options.ready.then =>
      config = @_config()
      return @_disabledState('disabled', config) unless config.configured

      request = OmegaPac.Conditions.requestFromUrl(url)
      @options.matchProfile(request).then (match) =>
        activeProfile = @options.currentProfile()
        manualMode = ProxyEnvironmentManager.isManualProxyProfile(activeProfile)
        enabled = ProxyEnvironmentManager.shouldEnableForMatch(
          match, activeProfile)
        {
          enabled: enabled
          timezone: config.timezone
          language: config.language
          profileName: match?.profile?.name ? ''
          reason: if enabled
            if manualMode then 'manual-proxy-profile' else 'explicit-proxy-rule'
          else
            'no-proxy-rule'
        }
    .catch((error) =>
      now = Date.now()
      if now - @_lastResolveErrorAt >= 60000
        @_lastResolveErrorAt = now
        @log.error('Failed to resolve proxy environment', error)
      @_disabledState('match-error')
    )

  onBeforeNavigate: (details) ->
    @_beginFrame(details)
    unless @_isMatchableUrl(details.url)
      state = @_inheritedState(details.tabId, details.frameId)
      @_remember(details.tabId, details.frameId, state, details.url)
      return
    @resolve(details.url).then (state) =>
      @_remember(details.tabId, details.frameId, state, details.url)

  onCommitted: (details) ->
    @_updateFrame(details)

  onHistoryStateUpdated: (details) ->
    @_updateFrame(details)

  onTabRemoved: (tabId) ->
    prefix = tabId + ':'
    for own key of @_frameStates when key.indexOf(prefix) == 0
      delete @_frameStates[key]
    for own key of @_frameParents when key.indexOf(prefix) == 0
      delete @_frameParents[key]
    for own key of @_frameUrls when key.indexOf(prefix) == 0
      delete @_frameUrls[key]
    @_queueHeaderRule(tabId, @_disabledState('tab-closed'))

  refreshAll: ->
    return unless @supported()
    chrome.tabs.query {}, (tabs) =>
      return if chrome.runtime.lastError
      for tab in tabs when tab.id?
        do (tab) =>
          chrome.webNavigation.getAllFrames {tabId: tab.id}, (frames) =>
            return if chrome.runtime.lastError or not frames
            @_refreshFrames(tab.id, frames)

  _refreshFrames: (tabId, frames) ->
    byId = {}
    pending = {}
    byId[frame.frameId] = frame for frame in frames
    refreshFrame = (frame) =>
      return pending[frame.frameId] if pending[frame.frameId]?
      wait = Promise.resolve()
      parent = byId[frame.parentFrameId]
      wait = refreshFrame(parent) if parent?
      pending[frame.frameId] = wait.then =>
        @_updateFrame({
          tabId: tabId
          frameId: frame.frameId
          parentFrameId: frame.parentFrameId
          url: frame.url
        })
    Promise.all(refreshFrame(frame) for frame in frames)

  scheduleRefreshAll: ->
    @_frameUrls = {}
    @_queueGlobalHeaderRule()
    clearTimeout(@_refreshTimer) if @_refreshTimer?
    @_refreshTimer = setTimeout((=> @refreshAll()), 50)

  _updateFrame: (details) ->
    @_beginFrame(details)
    if @_isMatchableUrl(details.url)
      getState = @resolve(details.url)
    else
      getState = Promise.resolve(
        @_inheritedState(details.tabId, details.frameId))

    getState.then (state) =>
      @_remember(details.tabId, details.frameId, state, details.url)
      @_send(details.tabId, details.frameId, state)

  _send: (tabId, frameId, state) ->
    chrome.tabs.sendMessage tabId, {
      method: 'proxyEnvironment.update'
      state: state
    }, {frameId: frameId}, -> chrome.runtime.lastError

  _remember: (tabId, frameId, state, url) ->
    return unless tabId?
    key = @_frameKey(tabId, frameId)
    return if url? and @_frameUrls[key]? and @_frameUrls[key] != url
    @_frameStates[key] = state
    @_frameUrls[key] = url if url?
    @_queueHeaderRule(tabId, state) if frameId == 0

  _restoreHeaderRules: ->
    api = chrome?.declarativeNetRequest
    return Promise.resolve(false) unless api?.getSessionRules?
    Promise.resolve(api.getSessionRules()).then (rules) =>
      for rule in rules ? [] when @_isHeaderRuleId(rule.id)
        value = rule.action?.requestHeaders?[0]?.value
        continue unless value?
        if rule.id == GLOBAL_HEADER_RULE_ID
          @_globalHeaderRule = {id: rule.id, value: value}
          @_headerRuleIds[rule.id] = true
          continue
        tabId = rule.condition?.tabIds?[0]
        continue unless tabId?
        @_headerRulesByTab[tabId] = {id: rule.id, value: value}
        @_headerRuleIds[rule.id] = true
      true
    .catch((error) =>
      @log.error('Failed to restore proxy environment header rules', error)
      false
    )

  _queueHeaderRule: (tabId, state) ->
    return unless tabId? and chrome?.declarativeNetRequest?.updateSessionRules?
    @_headerRuleQueue = @_headerRuleQueue.catch(-> null).then(=>
      @_headerRuleReady
    ).then(=> @_updateHeaderRule(tabId, state)).catch((error) =>
      now = Date.now()
      if now - @_lastResolveErrorAt >= 60000
        @_lastResolveErrorAt = now
        @log.error('Failed to update Accept-Language header', error)
      false
    )

  _queueGlobalHeaderRule: ->
    return unless chrome?.declarativeNetRequest?.updateSessionRules?
    @_headerRuleQueue = @_headerRuleQueue.catch(-> null).then(=>
      @_headerRuleReady
    ).then(=> @_updateGlobalHeaderRule()).catch((error) =>
      now = Date.now()
      if now - @_lastResolveErrorAt >= 60000
        @_lastResolveErrorAt = now
        @log.error('Failed to update global Accept-Language header', error)
      false
    )

  _updateGlobalHeaderRule: ->
    config = @_config()
    activeProfile = @options.currentProfile()
    manualMode = ProxyEnvironmentManager.isManualProxyProfile(activeProfile)
    value = if config.configured and manualMode
      Match.languageHeaderValue(config.language)
    else
      ''
    current = @_globalHeaderRule
    return true if current?.value == value
    return true unless value or current?

    removeRuleIds = []
    removeRuleIds.push(current.id) if current?
    if value
      for own tabId, rule of @_headerRulesByTab
        removeRuleIds.push(rule.id)
      addRules = [Match.buildLanguageHeaderRule(
        GLOBAL_HEADER_RULE_ID, null, config.language)]
    else
      addRules = []

    Promise.resolve(chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: removeRuleIds
      addRules: addRules
    })).then =>
      delete @_headerRuleIds[current.id] if current?
      @_globalHeaderRule = null
      if value
        for own tabId, rule of @_headerRulesByTab
          delete @_headerRuleIds[rule.id]
        @_headerRulesByTab = {}
        @_globalHeaderRule = {id: GLOBAL_HEADER_RULE_ID, value: value}
        @_headerRuleIds[GLOBAL_HEADER_RULE_ID] = true
      true

  _updateHeaderRule: (tabId, state) ->
    current = @_headerRulesByTab[tabId]
    value = if state?.enabled and not @_globalHeaderRule?
      Match.languageHeaderValue(state.language)
    else
      ''
    return true unless value or current?
    return true if current?.value == value

    removeRuleIds = []
    removeRuleIds.push(current.id) if current?
    addRules = []
    if value
      id = current?.id ? @_allocateHeaderRuleId()
      unless id?
        throw new Error('No proxy environment header rule IDs available')
      addRules.push(Match.buildLanguageHeaderRule(id, tabId, state.language))

    Promise.resolve(chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: removeRuleIds
      addRules: addRules
    })).then =>
      if current?
        delete @_headerRuleIds[current.id]
        delete @_headerRulesByTab[tabId]
      if addRules.length
        rule = addRules[0]
        @_headerRuleIds[rule.id] = true
        @_headerRulesByTab[tabId] = {id: rule.id, value: value}
      true

  _allocateHeaderRuleId: ->
    attempts = HEADER_RULE_ID_MAX - HEADER_RULE_ID_MIN + 1
    while attempts-- > 0
      id = @_nextHeaderRuleId
      @_nextHeaderRuleId++
      if @_nextHeaderRuleId > HEADER_RULE_ID_MAX
        @_nextHeaderRuleId = HEADER_RULE_ID_MIN
      return id unless @_headerRuleIds[id]
    null

  _isHeaderRuleId: (id) ->
    id == GLOBAL_HEADER_RULE_ID or
      id >= HEADER_RULE_ID_MIN and id <= HEADER_RULE_ID_MAX

  _beginFrame: (details) ->
    return unless details.tabId? and details.frameId?
    @_trackParent(details)
    return unless details.url?
    key = @_frameKey(details.tabId, details.frameId)
    if @_frameUrls[key] != details.url
      delete @_frameStates[key]
      @_frameUrls[key] = details.url

  _trackParent: (details) ->
    return unless details.tabId? and details.frameId? and
      details.parentFrameId?
    @_frameParents[@_frameKey(details.tabId, details.frameId)] =
      details.parentFrameId

  _inheritedState: (tabId, frameId) ->
    parentFrameId = @_frameParents[@_frameKey(tabId, frameId)]
    if parentFrameId? and parentFrameId >= 0
      state = @_frameStates[@_frameKey(tabId, parentFrameId)]
      return state if state?
    state = @_frameStates[@_frameKey(tabId, 0)]
    state ? @_disabledState('opaque-url')

  _frameKey: (tabId, frameId) ->
    tabId + ':' + (frameId ? 0)

  _isMatchableUrl: (url) ->
    typeof url == 'string' and /^https?:\/\//i.test(url)

  _changesAffectEnvironment: (changes) ->
    for own key of changes ? {}
      return true if key[0] == '+' or key in ENVIRONMENT_OPTION_KEYS
    false

  _config: ->
    all = @options.getAll() ? {}
    timezone = all['-proxyEnvironmentTimezone'] ? 'Etc/GMT'
    language = all['-proxyEnvironmentLanguage'] ? 'en-US'

    try
      timezone = new Intl.DateTimeFormat('en', {timeZone: timezone})
        .resolvedOptions().timeZone
    catch _
      timezone = 'Etc/GMT'

    try
      language = Intl.getCanonicalLocales(language)[0]
    catch _
      language = 'en-US'

    {
      configured: all['-proxyEnvironmentEnabled'] == true
      timezone: timezone
      language: language
    }

  _disabledState: (reason, config) ->
    config ?= @_config()
    {
      enabled: false
      timezone: config.timezone
      language: config.language
      profileName: ''
      reason: reason
    }

module.exports = ProxyEnvironmentManager
