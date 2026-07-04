#!/usr/bin/env node
'use strict';

const assert = require('assert');
const builder = require('./build-geosite');

function varint(value) {
  const out = [];
  while (value >= 0x80) {
    out.push((value & 0x7f) | 0x80);
    value = Math.floor(value / 128);
  }
  out.push(value);
  return Buffer.from(out);
}

function field(fieldNo, wireType, payload) {
  return Buffer.concat([varint(fieldNo * 8 + wireType), payload]);
}

function stringField(fieldNo, value) {
  const body = Buffer.from(value, 'utf8');
  return field(fieldNo, 2, Buffer.concat([varint(body.length), body]));
}

function varintField(fieldNo, value) {
  return field(fieldNo, 0, varint(value));
}

function messageField(fieldNo, parts) {
  const body = Buffer.concat(parts);
  return field(fieldNo, 2, Buffer.concat([varint(body.length), body]));
}

function attr(key) {
  return messageField(3, [
    stringField(1, key),
    varintField(2, 1)
  ]);
}

function domain(type, value, attrs) {
  return messageField(2, [
    varintField(1, type),
    stringField(2, value)
  ].concat((attrs || []).map(attr)));
}

function site(code, domains) {
  return messageField(1, [
    stringField(1, code)
  ].concat(domains));
}

const fixture = Buffer.concat([
  site('google', [
    domain(2, 'google.com'),
    domain(3, 'analytics.google.com', ['ads']),
    domain(0, 'google'),
    domain(1, '^odd[1-7]\\.example\\.org$')
  ]),
  site('cn', [
    domain(2, 'example.cn')
  ])
]);

const data = builder.buildData(fixture);
assert.deepStrictEqual(Object.keys(data.groups), ['cn', 'google']);
assert.deepStrictEqual(data.groups.cn.domain, ['example.cn']);
assert.deepStrictEqual(data.groups.google.full, ['analytics.google.com']);
assert.deepStrictEqual(data.groups.google.attrs.ads.full, ['analytics.google.com']);
assert.deepStrictEqual(data.groups.google.plain, ['google']);
assert.deepStrictEqual(data.groups.google.regexp, ['^odd[1-7]\\.example\\.org$']);

console.log('build-geosite fixture ok');
