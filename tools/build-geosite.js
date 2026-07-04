#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const TYPES = ['plain', 'regexp', 'domain', 'full'];

function usage() {
  return [
    'Usage: node tools/build-geosite.js [--input geo/geosite.dat] [--output omega-pac/src/geosite_data.js]',
    '',
    'Builds a compact ZeroOmega geosite data module from v2fly/domain-list-community geosite.dat/dlc.dat.'
  ].join('\n');
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
    } else if (arg === '--input' || arg === '-i') {
      args.input = argv[++i];
    } else if (arg === '--output' || arg === '-o') {
      args.output = argv[++i];
    } else {
      throw new Error('Unknown argument: ' + arg);
    }
  }
  return args;
}

function Reader(buffer) {
  this.buffer = buffer;
  this.pos = 0;
  this.end = buffer.length;
}

Reader.prototype.done = function () {
  return this.pos >= this.end;
};

Reader.prototype.varint = function () {
  let shift = 0;
  let value = 0;
  while (this.pos < this.end) {
    const byte = this.buffer[this.pos++];
    value += (byte & 0x7f) * Math.pow(2, shift);
    if ((byte & 0x80) === 0) return value;
    shift += 7;
  }
  throw new Error('Unexpected end while reading varint');
};

Reader.prototype.bytes = function () {
  const length = this.varint();
  const start = this.pos;
  const end = start + length;
  if (end > this.end) throw new Error('Length-delimited field exceeds buffer');
  this.pos = end;
  return this.buffer.slice(start, end);
};

Reader.prototype.string = function () {
  return this.bytes().toString('utf8');
};

Reader.prototype.skip = function (wireType) {
  switch (wireType) {
    case 0:
      this.varint();
      return;
    case 1:
      this.pos += 8;
      return;
    case 2:
      this.bytes();
      return;
    case 5:
      this.pos += 4;
      return;
    default:
      throw new Error('Unsupported protobuf wire type: ' + wireType);
  }
};

function decodeAttribute(buffer) {
  const reader = new Reader(buffer);
  const attr = {key: '', boolValue: true};
  while (!reader.done()) {
    const tag = reader.varint();
    const field = Math.floor(tag / 8);
    const wireType = tag & 7;
    if (field === 1 && wireType === 2) {
      attr.key = reader.string().toLowerCase();
    } else if (field === 2 && wireType === 0) {
      attr.boolValue = !!reader.varint();
    } else {
      reader.skip(wireType);
    }
  }
  return attr;
}

function decodeDomain(buffer) {
  const reader = new Reader(buffer);
  const domain = {type: 0, value: '', attrs: []};
  while (!reader.done()) {
    const tag = reader.varint();
    const field = Math.floor(tag / 8);
    const wireType = tag & 7;
    if (field === 1 && wireType === 0) {
      domain.type = reader.varint();
    } else if (field === 2 && wireType === 2) {
      domain.value = reader.string().toLowerCase();
    } else if (field === 3 && wireType === 2) {
      const attr = decodeAttribute(reader.bytes());
      if (attr.key && attr.boolValue !== false) domain.attrs.push(attr.key);
    } else {
      reader.skip(wireType);
    }
  }
  return domain;
}

function decodeGeoSite(buffer) {
  const reader = new Reader(buffer);
  const site = {code: '', domains: []};
  while (!reader.done()) {
    const tag = reader.varint();
    const field = Math.floor(tag / 8);
    const wireType = tag & 7;
    if (field === 1 && wireType === 2) {
      site.code = reader.string().toLowerCase();
    } else if (field === 2 && wireType === 2) {
      site.domains.push(decodeDomain(reader.bytes()));
    } else {
      reader.skip(wireType);
    }
  }
  return site;
}

function decodeGeoSiteList(buffer) {
  const reader = new Reader(buffer);
  const sites = [];
  while (!reader.done()) {
    const tag = reader.varint();
    const field = Math.floor(tag / 8);
    const wireType = tag & 7;
    if (field === 1 && wireType === 2) {
      sites.push(decodeGeoSite(reader.bytes()));
    } else {
      reader.skip(wireType);
    }
  }
  return sites;
}

function emptyGroup() {
  return {plain: [], regexp: [], domain: [], full: [], attrs: {}};
}

function addValue(group, type, value) {
  const bucket = TYPES[type];
  if (!bucket || !value) return;
  group[bucket].push(value);
}

function normalizeGroup(group) {
  for (const bucket of TYPES) {
    group[bucket] = Array.from(new Set(group[bucket])).sort();
  }
  const attrs = {};
  for (const attr of Object.keys(group.attrs).sort()) {
    attrs[attr] = normalizeGroup(group.attrs[attr]);
  }
  group.attrs = attrs;
  return group;
}

function buildData(buffer) {
  const groups = {};
  for (const site of decodeGeoSiteList(buffer)) {
    if (!site.code) continue;
    const group = groups[site.code] || (groups[site.code] = emptyGroup());
    for (const domain of site.domains) {
      addValue(group, domain.type, domain.value);
      for (const attr of domain.attrs) {
        const attrGroup = group.attrs[attr] || (group.attrs[attr] = emptyGroup());
        addValue(attrGroup, domain.type, domain.value);
      }
    }
  }
  const sortedGroups = {};
  for (const code of Object.keys(groups).sort()) {
    sortedGroups[code] = normalizeGroup(groups[code]);
  }
  return {version: 1, groups: sortedGroups};
}

function writeModule(output, data) {
  const text = [
    '// Generated by tools/build-geosite.js.',
    '// Source: v2fly/domain-list-community dlc.dat.',
    'module.exports = ' + JSON.stringify(data) + ';',
    ''
  ].join('\r\n');
  fs.mkdirSync(path.dirname(output), {recursive: true});
  fs.writeFileSync(output, text, 'utf8');
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(usage());
    return;
  }
  args.input = args.input || path.join('geo', 'geosite.dat');
  args.output = args.output || path.join('omega-pac', 'src', 'geosite_data.js');
  const data = buildData(fs.readFileSync(args.input));
  writeModule(args.output, data);
  console.log('geosite groups: ' + Object.keys(data.groups).length);
  console.log('output: ' + outputPath(args.output));
}

function outputPath(file) {
  return path.relative(process.cwd(), path.resolve(file)) || file;
}

module.exports = {
  buildData,
  decodeGeoSiteList,
  writeModule
};

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(err.message || err);
    process.exit(1);
  }
}
