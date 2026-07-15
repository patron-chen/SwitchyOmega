/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Adapted from https://github.com/joue-quroi/spoof-timezone. This MPL-2.0 file
 * is combined with this
 * GPL-3.0-or-later project under section 3.3 of the MPL 2.0.
 */
(() => {
  'use strict';

  const MARKER = 'data-zero-omega-proxy-environment-port';
  const VERSION = 'v1';
  const CHANGE_EVENT = 'zero-omega-proxy-environment-change';
  const MINUTE = 60 * 1000;
  const OFFSET_SEARCH_WINDOW = 36 * 60 * MINUTE;

  const getPort = () => {
    let port = document.querySelector(`[${MARKER}="${VERSION}"]`);
    if (port) {
      return port;
    }

    port = document.createElement('span');
    port.setAttribute(MARKER, VERSION);
    port.setAttribute('data-enabled', 'false');
    port.setAttribute('data-timezone', 'Etc/GMT');
    port.setAttribute('data-language', 'en-US');
    port.setAttribute('aria-hidden', 'true');
    port.style.display = 'none';
    document.documentElement.appendChild(port);
    return port;
  };

  const port = getPort();
  const NativeDate = self.Date;
  const NativeDatePrototype = NativeDate.prototype;
  const NativeIntl = {};
  const intlNames = [
    'Collator',
    'DateTimeFormat',
    'DisplayNames',
    'DurationFormat',
    'ListFormat',
    'NumberFormat',
    'PluralRules',
    'RelativeTimeFormat',
    'Segmenter'
  ];

  for (const name of intlNames) {
    if (typeof Intl[name] === 'function') {
      NativeIntl[name] = Intl[name];
    }
  }

  const NativeDateTimeFormat = NativeIntl.DateTimeFormat;
  const nativeGetCanonicalLocales = Intl.getCanonicalLocales.bind(Intl);
  const nativeNavigatorLanguage = navigator.language;
  const nativeNavigatorLanguages = navigator.languages ||
    Object.freeze([nativeNavigatorLanguage]);

  let state = {
    enabled: false,
    timezone: 'Etc/GMT',
    language: 'en-US',
    languages: Object.freeze(['en-US', 'en'])
  };

  const languageList = language => {
    let base = language.split('-')[0];
    try {
      if (typeof Intl.Locale === 'function') {
        base = new Intl.Locale(language).language;
      }
    }
    catch (_) {}
    return Object.freeze(base && base !== language ? [language, base] : [language]);
  };

  const readState = () => {
    let timezone = port.getAttribute('data-timezone') || 'Etc/GMT';
    let language = port.getAttribute('data-language') || 'en-US';

    try {
      timezone = new NativeDateTimeFormat('en', {timeZone: timezone})
        .resolvedOptions().timeZone;
    }
    catch (_) {
      timezone = 'Etc/GMT';
    }

    try {
      language = nativeGetCanonicalLocales(language)[0];
    }
    catch (_) {
      language = 'en-US';
    }

    state = {
      enabled: port.getAttribute('data-enabled') === 'true',
      timezone,
      language,
      languages: languageList(language)
    };
    offsetFormatter = null;
    offsetFormatterTimezone = '';
    zoneNameFormatter = null;
    zoneNameFormatterTimezone = '';
  };

  let offsetFormatter = null;
  let offsetFormatterTimezone = '';
  let zoneNameFormatter = null;
  let zoneNameFormatterTimezone = '';

  const offsetFor = time => {
    if (!Number.isFinite(time)) {
      return NaN;
    }
    if (!offsetFormatter || offsetFormatterTimezone !== state.timezone) {
      offsetFormatter = new NativeDateTimeFormat('en-US', {
        timeZone: state.timezone,
        timeZoneName: 'longOffset'
      });
      offsetFormatterTimezone = state.timezone;
    }

    const part = offsetFormatter.formatToParts(new NativeDate(time))
      .find(item => item.type === 'timeZoneName');
    const value = part ? part.value : 'GMT';
    if (value === 'GMT' || value === 'UTC') {
      return 0;
    }
    const match = /^GMT([+-])(\d{1,2})(?::?(\d{2}))?(?::?(\d{2}))?$/.exec(value);
    if (!match) {
      return 0;
    }
    const minutes = Number(match[2]) * 60 + Number(match[3] || 0) +
      Number(match[4] || 0) / 60;
    return match[1] === '-' ? -minutes : minutes;
  };

  const makeWallEpoch = (year, month, date, hours, minutes, seconds, milliseconds) => {
    const wall = new NativeDate(0);
    NativeDatePrototype.setUTCFullYear.call(wall, year, month, date);
    NativeDatePrototype.setUTCHours.call(
      wall, hours, minutes, seconds, milliseconds);
    return NativeDatePrototype.getTime.call(wall);
  };

  const targetWallEpoch = time => time + offsetFor(time) * MINUTE;

  const wallToInstant = (year, month, date, hours, minutes, seconds, milliseconds) => {
    const wallEpoch = makeWallEpoch(
      year, month, date, hours, minutes, seconds, milliseconds);
    const offsets = new Set([
      offsetFor(wallEpoch - OFFSET_SEARCH_WINDOW),
      offsetFor(wallEpoch),
      offsetFor(wallEpoch + OFFSET_SEARCH_WINDOW)
    ]);
    const candidates = [];

    for (const offset of offsets) {
      if (Number.isFinite(offset)) {
        const instant = wallEpoch - offset * MINUTE;
        candidates.push({instant, represented: targetWallEpoch(instant)});
      }
    }

    const exact = candidates
      .filter(candidate => candidate.represented === wallEpoch)
      .sort((a, b) => a.instant - b.instant);
    if (exact.length) {
      return exact[0].instant;
    }

    const afterGap = candidates
      .filter(candidate => candidate.represented > wallEpoch)
      .sort((a, b) => a.represented - b.represented);
    if (afterGap.length) {
      return afterGap[0].instant;
    }

    return candidates.length ? candidates[0].instant : wallEpoch;
  };

  const wallDate = date => new NativeDate(
    NativeDatePrototype.getTime.call(date) +
    offsetFor(NativeDatePrototype.getTime.call(date)) * MINUTE);

  const instantFromNativeLocalDate = date => wallToInstant(
    NativeDatePrototype.getFullYear.call(date),
    NativeDatePrototype.getMonth.call(date),
    NativeDatePrototype.getDate.call(date),
    NativeDatePrototype.getHours.call(date),
    NativeDatePrototype.getMinutes.call(date),
    NativeDatePrototype.getSeconds.call(date),
    NativeDatePrototype.getMilliseconds.call(date)
  );

  const isoDatetimeWithOffset = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?([.,]\d+)?([Zz]|[+-]\d{2}:?\d{2})$/;
  const isoDateOnly = /^\d{4}-\d{2}-\d{2}$/;
  const namedTimezone = /\b(?:UT|UTC|GMT|[ECMP][SD]T)\b/i;
  const trailingOffset = /[+-]\d{2}:?\d{2}(?:\s*\([^)]*\))?$/;
  const isLocalDateArgs = args => {
    if (args.length === 0) {
      return false;
    }
    if (args.length > 1) {
      return true;
    }
    const value = args[0];
    if (value instanceof NativeDate || typeof value === 'number') {
      return false;
    }
    if (typeof value !== 'string') {
      return false;
    }
    const input = value.trim();
    return !isoDatetimeWithOffset.test(input) && !isoDateOnly.test(input) &&
      !namedTimezone.test(input) && !trailingOffset.test(input);
  };

  const utcGetterForLocal = {
    getDate: 'getUTCDate',
    getDay: 'getUTCDay',
    getFullYear: 'getUTCFullYear',
    getHours: 'getUTCHours',
    getMilliseconds: 'getUTCMilliseconds',
    getMinutes: 'getUTCMinutes',
    getMonth: 'getUTCMonth',
    getSeconds: 'getUTCSeconds'
  };

  const utcSetterForLocal = {
    setDate: 'setUTCDate',
    setFullYear: 'setUTCFullYear',
    setHours: 'setUTCHours',
    setMilliseconds: 'setUTCMilliseconds',
    setMinutes: 'setUTCMinutes',
    setMonth: 'setUTCMonth',
    setSeconds: 'setUTCSeconds'
  };

  const getLocal = (date, name, args) => {
    if (!state.enabled) {
      return NativeDatePrototype[name].apply(date, args);
    }
    const wall = wallDate(date);
    return NativeDatePrototype[utcGetterForLocal[name]].apply(wall, args);
  };

  const setLocal = (date, name, args) => {
    if (!state.enabled) {
      return NativeDatePrototype[name].apply(date, args);
    }

    const invalid = Number.isNaN(NativeDatePrototype.getTime.call(date));
    if (invalid && name !== 'setFullYear') {
      return NativeDatePrototype[name].apply(date, args);
    }
    const wall = invalid ? new NativeDate(NaN) : wallDate(date);
    const utcSetter = utcSetterForLocal[name];
    NativeDatePrototype[utcSetter].apply(wall, args);
    const result = wallToInstant(
      NativeDatePrototype.getUTCFullYear.call(wall),
      NativeDatePrototype.getUTCMonth.call(wall),
      NativeDatePrototype.getUTCDate.call(wall),
      NativeDatePrototype.getUTCHours.call(wall),
      NativeDatePrototype.getUTCMinutes.call(wall),
      NativeDatePrototype.getUTCSeconds.call(wall),
      NativeDatePrototype.getUTCMilliseconds.call(wall)
    );
    NativeDatePrototype.setTime.call(date, result);
    return result;
  };

  const localeArguments = (input, withTimezone) => {
    const args = Array.from(input);
    if (args[0] === undefined) {
      args[0] = state.language;
    }
    if (withTimezone) {
      if (args[1] === null) {
        return args;
      }
      const options = args[1] === undefined ? {} : Object.assign({}, args[1]);
      if (options.timeZone === undefined) {
        options.timeZone = state.timezone;
      }
      args[1] = options;
    }
    return args;
  };

  const zoneName = date => {
    if (!zoneNameFormatter || zoneNameFormatterTimezone !== state.timezone) {
      zoneNameFormatter = new NativeDateTimeFormat('en-US', {
        timeZone: state.timezone,
        timeZoneName: 'long'
      });
      zoneNameFormatterTimezone = state.timezone;
    }
    const part = zoneNameFormatter.formatToParts(date)
      .find(item => item.type === 'timeZoneName');
    return part ? part.value : state.timezone;
  };

  const pad2 = value => String(value).padStart(2, '0');
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  class SpoofDate extends NativeDate {
    constructor(...args) {
      super(...args);
      if (state.enabled && isLocalDateArgs(args) && !Number.isNaN(
        NativeDatePrototype.getTime.call(this))) {
        const local = new NativeDate(...args);
        NativeDatePrototype.setTime.call(this, instantFromNativeLocalDate(local));
      }
    }

    static parse(value) {
      const parsed = NativeDate.parse(value);
      if (!state.enabled || !Number.isFinite(parsed) ||
          !isLocalDateArgs([value])) {
        return parsed;
      }
      return instantFromNativeLocalDate(new NativeDate(parsed));
    }

    getTimezoneOffset() {
      if (!state.enabled || Number.isNaN(NativeDatePrototype.getTime.call(this))) {
        return NativeDatePrototype.getTimezoneOffset.call(this);
      }
      return -Math.trunc(offsetFor(NativeDatePrototype.getTime.call(this)));
    }

    getDate(...args) { return getLocal(this, 'getDate', args); }
    getDay(...args) { return getLocal(this, 'getDay', args); }
    getFullYear(...args) { return getLocal(this, 'getFullYear', args); }
    getHours(...args) { return getLocal(this, 'getHours', args); }
    getMilliseconds(...args) { return getLocal(this, 'getMilliseconds', args); }
    getMinutes(...args) { return getLocal(this, 'getMinutes', args); }
    getMonth(...args) { return getLocal(this, 'getMonth', args); }
    getSeconds(...args) { return getLocal(this, 'getSeconds', args); }
    getYear() { return this.getFullYear() - 1900; }

    setDate(...args) { return setLocal(this, 'setDate', args); }
    setFullYear(...args) { return setLocal(this, 'setFullYear', args); }
    setHours(...args) { return setLocal(this, 'setHours', args); }
    setMilliseconds(...args) { return setLocal(this, 'setMilliseconds', args); }
    setMinutes(...args) { return setLocal(this, 'setMinutes', args); }
    setMonth(...args) { return setLocal(this, 'setMonth', args); }
    setSeconds(...args) { return setLocal(this, 'setSeconds', args); }
    setYear(value) {
      if (!state.enabled) {
        return NativeDatePrototype.setYear.call(this, value);
      }
      value = Number(value);
      if (Number.isNaN(value)) {
        return NativeDatePrototype.setTime.call(this, NaN);
      }
      if (value >= 0 && value <= 99) {
        value += 1900;
      }
      return setLocal(this, 'setFullYear', [value]);
    }

    toDateString() {
      if (!state.enabled || Number.isNaN(NativeDatePrototype.getTime.call(this))) {
        return NativeDatePrototype.toDateString.call(this);
      }
      const wall = wallDate(this);
      return weekdays[wall.getUTCDay()] + ' ' + months[wall.getUTCMonth()] +
        ' ' + pad2(wall.getUTCDate()) + ' ' + wall.getUTCFullYear();
    }

    toTimeString() {
      if (!state.enabled || Number.isNaN(NativeDatePrototype.getTime.call(this))) {
        return NativeDatePrototype.toTimeString.call(this);
      }
      const wall = wallDate(this);
      const offset = offsetFor(NativeDatePrototype.getTime.call(this));
      const sign = offset < 0 ? '-' : '+';
      const absolute = Math.trunc(Math.abs(offset));
      const offsetText = sign + pad2(Math.floor(absolute / 60)) +
        pad2(absolute % 60);
      return pad2(wall.getUTCHours()) + ':' + pad2(wall.getUTCMinutes()) +
        ':' + pad2(wall.getUTCSeconds()) + ' GMT' + offsetText +
        ' (' + zoneName(this) + ')';
    }

    toString() {
      if (!state.enabled) {
        return NativeDatePrototype.toString.call(this);
      }
      if (Number.isNaN(NativeDatePrototype.getTime.call(this))) {
        return NativeDatePrototype.toString.call(this);
      }
      return this.toDateString() + ' ' + this.toTimeString();
    }

    toLocaleDateString(...args) {
      if (state.enabled) {
        args = localeArguments(args, true);
      }
      return NativeDatePrototype.toLocaleDateString.apply(this, args);
    }

    toLocaleTimeString(...args) {
      if (state.enabled) {
        args = localeArguments(args, true);
      }
      return NativeDatePrototype.toLocaleTimeString.apply(this, args);
    }

    toLocaleString(...args) {
      if (state.enabled) {
        args = localeArguments(args, true);
      }
      return NativeDatePrototype.toLocaleString.apply(this, args);
    }
  }

  Object.defineProperties(SpoofDate, {
    name: {value: 'Date'},
    length: {value: 7}
  });
  Object.defineProperty(SpoofDate.parse, 'length', {value: 1});

  const DateFacade = function Date() {};
  Object.defineProperties(DateFacade, {
    length: {value: 7},
    prototype: {value: SpoofDate.prototype},
    now: Object.getOwnPropertyDescriptor(NativeDate, 'now'),
    parse: {value: SpoofDate.parse, configurable: true, writable: true},
    UTC: Object.getOwnPropertyDescriptor(NativeDate, 'UTC')
  });
  const DateProxy = new Proxy(DateFacade, {
    apply() {
      return state.enabled ? new SpoofDate().toString() : NativeDate();
    },
    construct(target, args, newTarget) {
      return Reflect.construct(
        SpoofDate,
        args,
        newTarget === DateProxy ? SpoofDate : newTarget
      );
    }
  });
  Object.defineProperty(SpoofDate.prototype, 'constructor', {
    value: DateProxy,
    configurable: true,
    writable: true
  });
  self.Date = DateProxy;

  const prepareIntlArguments = (name, input) => {
    const args = Array.from(input);
    if (!state.enabled) {
      return args;
    }
    if (args[0] === undefined) {
      args[0] = state.language;
    }
    if (name === 'DateTimeFormat') {
      if (args[1] === null) {
        return args;
      }
      const options = args[1] === undefined ? {} : Object.assign({}, args[1]);
      if (options.timeZone === undefined) {
        options.timeZone = state.timezone;
      }
      args[1] = options;
    }
    return args;
  };

  for (const name of Object.keys(NativeIntl)) {
    const NativeConstructor = NativeIntl[name];
    const descriptor = Object.getOwnPropertyDescriptor(Intl, name);
    let proxy;
    proxy = new Proxy(NativeConstructor, {
      apply(target, thisArg, args) {
        return Reflect.apply(target, thisArg, prepareIntlArguments(name, args));
      },
      construct(target, args, newTarget) {
        return Reflect.construct(
          target,
          prepareIntlArguments(name, args),
          newTarget === proxy ? target : newTarget
        );
      }
    });
    Object.defineProperty(Intl, name, Object.assign({}, descriptor, {value: proxy}));
  }

  const wrapLocaleMethod = (prototype, name) => {
    if (!prototype || typeof prototype[name] !== 'function') {
      return;
    }
    const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
    const nativeMethod = descriptor.value;
    descriptor.value = new Proxy(nativeMethod, {
      apply(target, thisArg, args) {
        if (state.enabled && args[0] === undefined) {
          args = Array.from(args);
          args[0] = state.language;
        }
        return Reflect.apply(target, thisArg, args);
      }
    });
    Object.defineProperty(prototype, name, descriptor);
  };

  wrapLocaleMethod(Number.prototype, 'toLocaleString');
  if (typeof BigInt === 'function') {
    wrapLocaleMethod(BigInt.prototype, 'toLocaleString');
  }

  const defineNavigatorValue = (name, nativeValue, spoofedValue) => {
    const getter = () => state.enabled ? spoofedValue() : nativeValue;
    try {
      Object.defineProperty(navigator, name, {configurable: true, get: getter});
    }
    catch (_) {
      const prototype = Object.getPrototypeOf(navigator);
      Object.defineProperty(prototype, name, {configurable: true, get: getter});
    }
  };

  defineNavigatorValue('language', nativeNavigatorLanguage, () => state.language);
  defineNavigatorValue('languages', nativeNavigatorLanguages, () => state.languages);

  port.addEventListener(CHANGE_EVENT, readState);
  readState();
})();
