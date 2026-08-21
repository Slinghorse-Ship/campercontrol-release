import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const releaseRoot = path.resolve(scriptDirectory, '..');
const dashboardRoot = path.join(releaseRoot, 'artifacts', 'node-red');
const dashboardTemplatePath = path.join(dashboardRoot, 'camper-dashboard.html');
const dashboardV2MarkupPath = path.join(dashboardRoot, 'camper-dashboard-v2.html');
const dashboardV2CssPath = path.join(dashboardRoot, 'camper-dashboard-v2.css');
const transitDarkPath = path.join(dashboardRoot, 'camper-assets', 'transit-line-symbol-dark.png');
const transitLightPath = path.join(dashboardRoot, 'camper-assets', 'transit-line-symbol-light.png');
const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const port = Number(arg('--port', '4175'));
const cerboBase = arg('--cerbo', 'http://venus.local:1880').replace(/\/$/, '');
const vueUrl = 'https://unpkg.com/vue@3.5.13/dist/vue.global.prod.js';

const dashboardTemplate = fs.readFileSync(dashboardTemplatePath, 'utf8');
const transitDataUri = filePath => `data:image/png;base64,${fs.readFileSync(filePath).toString('base64')}`;
const dashboardV2Markup = fs.readFileSync(dashboardV2MarkupPath, 'utf8')
  .replace('__CC2_TRANSIT_DARK_DATA_URI__', transitDataUri(transitDarkPath))
  .replace('__CC2_TRANSIT_LIGHT_DATA_URI__', transitDataUri(transitLightPath))
  .trim();
const dashboardV2Css = fs.readFileSync(dashboardV2CssPath, 'utf8').trim();
const dashboard = dashboardTemplate
  .replace('<!-- CAMPERCONTROL_V2_MARKUP -->', dashboardV2Markup)
  .replace('/* CAMPERCONTROL_V2_CSS */', dashboardV2Css);

const scriptStart = dashboard.indexOf('<script>');
const scriptEnd = dashboard.indexOf('</script>', scriptStart);
if (scriptStart < 0 || scriptEnd < 0) throw new Error('Dashboard-Script fehlt');
const beforeScript = dashboard.slice(0, scriptStart);
const outerTemplate = beforeScript
  .replace(/^\s*<template>\s*/, '')
  .replace(/\s*<\/template>\s*$/, '');
const componentScript = dashboard.slice(scriptStart + '<script>'.length, scriptEnd)
  .replace(/^\s*export\s+default/, 'window.__CAMPER_COMPONENT__ =');
const styles = [...dashboard.matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>/g)]
  .map(match => `<style>${match[1]}</style>`)
  .join('\n');

let vueCache = null;
const fetchVue = async () => {
  if (vueCache) return vueCache;
  const response = await fetch(vueUrl);
  if (!response.ok) throw new Error(`Vue-Laufzeit HTTP ${response.status}`);
  vueCache = Buffer.from(await response.arrayBuffer());
  return vueCache;
};
const fetchLiveState = async () => {
  const response = await fetch(`${cerboBase}/camper/api/v2/state`, { signal: AbortSignal.timeout(8000) });
  if (!response.ok) throw new Error(`Camper-API HTTP ${response.status}`);
  const payload = await response.json();
  const state = payload && payload.state;
  if (!state || Number(state.apiVersion) !== 2) throw new Error('Camper-API lieferte keinen v2-State');
  return state;
};
const html = (state, query) => {
  const allowedPages = new Set(['home', 'lights', 'climate', 'energy', 'water', 'system']);
  const allowedPanes = new Set(['power', 'sources', 'solar-detail']);
  const page = allowedPages.has(query.get('page')) ? query.get('page') : 'home';
  const pane = allowedPanes.has(query.get('pane')) ? query.get('pane') : 'power';
  const design = 'v2';
  const dayMode = query.get('theme') === 'light';
  const preview = JSON.stringify({ page, pane, design, dayMode }).replace(/</g, '\\u003c');
  const previewState = { ...state, ui: { ...(state.ui || {}), designVersion: design } };
  const snapshot = JSON.stringify(previewState).replace(/</g, '\\u003c');
  return `<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"><title>CamperControl V2 Preview</title>${styles}<style>html,body,#app{width:100%;height:100%;margin:0;overflow:hidden;background:#030609}</style></head>
<body><div id="app">${outerTemplate}</div><script src="/vue.js"></script><script>window.__CAMPER_SNAPSHOT__=${snapshot};window.__CAMPER_PREVIEW__=${preview};${componentScript}
const originalData=window.__CAMPER_COMPONENT__.data;
window.__CAMPER_COMPONENT__.data=function(){return Object.assign(originalData.call(this),{s:window.__CAMPER_SNAPSHOT__,v2Page:window.__CAMPER_PREVIEW__.page,v2EnergyPane:window.__CAMPER_PREVIEW__.pane,dayMode:window.__CAMPER_PREVIEW__.dayMode})};
window.__CAMPER_COMPONENT__.methods.send=function(message){console.info('Preview bleibt read-only',message)};
Vue.createApp(window.__CAMPER_COMPONENT__).mount('#app');</script></body></html>`;
};

const send = (response, status, contentType, body) => {
  response.writeHead(status, { 'Content-Type': contentType, 'Cache-Control': 'no-store' });
  response.end(body);
};
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url || '/', `http://${request.headers.host || '127.0.0.1'}`);
    if (request.method !== 'GET') return send(response, 405, 'text/plain; charset=utf-8', 'Read-only preview');
    if (url.pathname === '/health') return send(response, 200, 'application/json; charset=utf-8', JSON.stringify({ ok: true, cerboBase }));
    if (url.pathname === '/vue.js') return send(response, 200, 'text/javascript; charset=utf-8', await fetchVue());
    if (url.pathname.startsWith('/camper-assets/')) {
      const asset = await fetch(`${cerboBase}${url.pathname}`, { signal: AbortSignal.timeout(8000) });
      if (!asset.ok) return send(response, asset.status, 'text/plain; charset=utf-8', 'Asset nicht verfügbar');
      return send(response, 200, asset.headers.get('content-type') || 'application/octet-stream', Buffer.from(await asset.arrayBuffer()));
    }
    if (url.pathname !== '/') return send(response, 404, 'text/plain; charset=utf-8', 'Nicht gefunden');
    return send(response, 200, 'text/html; charset=utf-8', html(await fetchLiveState(), url.searchParams));
  } catch (error) {
    return send(response, 503, 'text/plain; charset=utf-8', `Preview nicht verfügbar: ${error.message}`);
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(JSON.stringify({
    ok: true,
    readOnly: true,
    url: `http://127.0.0.1:${port}/`,
    cerboBase,
    pages: ['home', 'lights', 'energy/power', 'energy/sources', 'energy/solar-detail', 'climate', 'water', 'system']
  }, null, 2));
});
