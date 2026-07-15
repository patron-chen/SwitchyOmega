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

  const apply = state => {
    state = state || {};
    port.setAttribute('data-enabled', state.enabled === true ? 'true' : 'false');
    port.setAttribute('data-timezone', state.timezone || 'Etc/GMT');
    port.setAttribute('data-language', state.language || 'en-US');
    port.dispatchEvent(new Event(CHANGE_EVENT));
  };

  chrome.runtime.onMessage.addListener(message => {
    if (message && message.method === 'proxyEnvironment.update') {
      apply(message.state);
    }
  });

  chrome.runtime.sendMessage({
    method: 'getProxyEnvironment',
    args: [{
      url: location.href,
      referrer: document.referrer
    }]
  }, response => {
    if (chrome.runtime.lastError) {
      apply(null);
      return;
    }
    apply(response && response.result);
  });
})();
