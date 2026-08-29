hasExplicitRuleMatch = (results) ->
  for result in results ? []
    if result and not Array.isArray(result) and result.profileName?
      return true
  false

isProxyProfile = (profile) ->
  return false unless profile?.profileType
  profile.profileType not in ['DirectProfile', 'SystemProfile']

isManualProxyProfile = (profile) ->
  profile?.profileType in [
    'FixedProfile'
    'PacProfile'
    'AutoDetectProfile'
  ]

isResolvedMatch = (match) ->
  profile = match?.profile
  results = match?.results
  return false unless profile?.name? and results?
  return true unless results.length

  result = results[results.length - 1]
  if Array.isArray(result) and result[1] == null
    return '+' + profile.name == result[0]
  if result?.profileName?
    return profile.name == result.profileName
  true

shouldEnableForMatch = (match, activeProfile) ->
  return false unless isResolvedMatch(match) and isProxyProfile(match?.profile)
  hasExplicitRuleMatch(match?.results) or isManualProxyProfile(activeProfile)

languageHeaderValue = (language) ->
  return '' unless typeof language == 'string' and language.length
  base = language.split('-')[0]
  return language if base.toLowerCase() == language.toLowerCase()
  language + ',' + base + ';q=0.9'

buildLanguageHeaderRule = (id, tabId, language) ->
  condition = {urlFilter: '|http'}
  condition.tabIds = [tabId] if tabId?
  {
    id: id
    priority: 1
    action:
      type: 'modifyHeaders'
      requestHeaders: [{
        header: 'Accept-Language'
        operation: 'set'
        value: languageHeaderValue(language)
      }]
    condition: condition
  }

module.exports = {
  hasExplicitRuleMatch
  isProxyProfile
  isManualProxyProfile
  isResolvedMatch
  shouldEnableForMatch
  languageHeaderValue
  buildLanguageHeaderRule
}
