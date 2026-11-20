// Execution test for Model.js: run `node scripts/test-model.js` from the repo root.
// The .pragma line is stripped and the module is exercised as plain ES5.
const fs = require('fs')
const file = process.argv[2] || require('node:path').join(__dirname, '..', 'Model.js')
const src = fs.readFileSync(file, 'utf8').split('\n').filter((l) => !l.startsWith('.pragma')).join('\n')

const names = [
  'languageName', 'languageShort', 'languageIndex', 'isKnownLanguage', 'findLanguages',
  'languageList', 'models', 'styleForModel', 'detectSource', 'resolvePair',
  'instructionPrompt', 'isShortPhrase', 'stripStress', 'requestBody', 'parseReply',
  'errorFromBody', 'cleanText', 'preview', 'makeEntry', 'parseHistory', 'pushHistory',
  'parseConfig', 'completionsUrl', 'modelLabel', 'pairCode', 'stripNoise'
]
const mod = new Function(src + '\nreturn {' + names.join(',') + '};')()

let failures = 0
function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected)
  const ok = a === e
  if (!ok) { failures++; console.log('FAIL ' + name + `  got ${a} want ${e}`) }
  else console.log('ok   ' + name)
}

// ---- language table (his addition: 42 targets, picker search)
check('42 languages', mod.languageList().length, 42)
check('known code', mod.isKnownLanguage('fr'), true)
check('unknown code', mod.isKnownLanguage('xx'), false)
check('code is case-insensitive', mod.isKnownLanguage('DE'), true)
check('name of fr', mod.languageName('fr'), 'French')
check('unknown falls back to English', mod.languageName('xx'), 'English')
check('short label', mod.languageShort('de'), 'DE')
check('picker puts code prefix first', mod.findLanguages('fr')[0].code, 'fr')
check('picker also reaches names', mod.findLanguages('fr').map((r) => r.code), ['fr', 'af'])
check('picker by name', mod.findLanguages('russ').map((r) => r.code), ['ru'])
check('picker empty query lists all', mod.findLanguages('').length, 42)

// ---- short phrase detection (his addition)
check('one word is short', mod.isShortPhrase('Linie'), true)
check('three words is short', mod.isShortPhrase('die rote Linie'), true)
check('four words is not', mod.isShortPhrase('die rote Linie hier'), false)
check('empty is not short', mod.isShortPhrase('   '), false)
check('punctuation only is not short', mod.isShortPhrase('— … ,'), false)
check('umlaut word counts once', mod.isShortPhrase('Straße'), true)

// ---- stress marks (his addition)
check('acute stripped', mod.stripStress('сло\u0301во'), 'слово')
check('cleanText strips stress', mod.cleanText('сло\u0301во', 100), 'слово')

// ---- model chain: short German phrase swaps instruction model first
const cfg = mod.parseConfig(JSON.stringify({
  apiKey: 'k', model: 'nvidia/riva-translate-4b-instruct-v2',
  fallbackModel: 'nvidia/nemotron-3.5-lightning-30b-a3b'
}))
check('default swap off for prose', mod.models(cfg, 'Die Linie ist heute gesperrt')[0], 'nvidia/riva-translate-4b-instruct-v2')
check('swap on for short phrase', mod.models(cfg, 'Linie')[0], 'nvidia/nemotron-3.5-lightning-30b-a3b')
check('swap keeps both models', mod.models(cfg, 'Linie').length, 2)
check('no fallback, no swap', mod.models(mod.parseConfig('{"model":"nvidia/riva-translate-4b-instruct-v2","fallbackModel":""}'), 'Linie').length, 1)
check('two instruction models never swap', mod.models(mod.parseConfig('{"model":"a/x","fallbackModel":"b/y"}'), 'Linie')[0], 'a/x')

// ---- pair detection
check('ru detected', mod.detectSource('Привет мир'), 'ru')
check('de by umlaut', mod.detectSource('Die Straße'), 'de')
check('en by default', mod.detectSource('hello there'), 'en')
check('ru target flips to de', mod.resolvePair('Привет', 'ru'), { source: 'ru', target: 'de' })
check('fr target accepts en source', mod.resolvePair('hello', 'fr'), { source: 'en', target: 'fr' })

// ---- request bodies
const pair = { source: 'de', target: 'ru' }
const riva = JSON.parse(mod.requestBody(cfg, 'nvidia/riva-translate-4b-instruct-v2', 'Hallo', pair))
check('riva system is pair code', riva.messages[0].content, 'de-ru')
check('thinking disabled', riva.chat_template_kwargs.enable_thinking, false)
check('riva model id', riva.model, 'nvidia/riva-translate-4b-instruct-v2')
const chat = JSON.parse(mod.requestBody(cfg, 'nvidia/nemotron-3.5-lightning-30b-a3b', 'Hallo', { source: 'de', target: 'ru' }))
check('chat system names target', chat.messages[0].content.indexOf('Russian') > 0, true)
const germanPrompt = mod.instructionPrompt('de')
check('german prompt asks for article', germanPrompt.indexOf('definite article') > 0, true)
check('russian prompt asks for no article rule', mod.instructionPrompt('ru').indexOf('definite article'), -1)
check('german example present', mod.instructionPrompt('de').indexOf("'Der Tisch'") > 0, true)

// ---- replies
check('200 parses', mod.parseReply(200, JSON.stringify({ choices: [{ message: { content: 'Привет' } }] })), { ok: true, text: 'Привет' })
check('fence stripped', mod.parseReply(200, JSON.stringify({ choices: [{ message: { content: '```\nHallo\n```' } }] })).text, 'Hallo')
check('401 english', mod.parseReply(401, '{}').error, 'Key rejected (401)')
check('429 english', mod.parseReply(429, '{}').error, 'Rate limit, try again later (429)')
check('404 english', mod.parseReply(404, '{}').error, 'Model or address not found (404)')
check('provider message kept', mod.parseReply(400, JSON.stringify({ error: { message: 'nope' } })).error, 'Error 400: nope')
check('empty translation fails', mod.parseReply(200, JSON.stringify({ choices: [{ message: { content: '' } }] })).ok, false)
check('no choices fails', mod.parseReply(200, '{}').ok, false)
check('non json fails', mod.parseReply(200, '<html>').ok, false)

// ---- config round trip (settings screen writes back what it read)
const raw = JSON.stringify({
  apiKey: 'nvapi-x', model: 'nvidia/a', fallbackModel: 'nvidia/b',
  endpoint: 'https://integrate.api.nvidia.com/v1', maxChars: 1500
})
const back = mod.parseConfig(raw)
const next = {}
for (const k in back) next[k] = back[k]
check('config keys survive write-back',
  Object.keys(mod.parseConfig(JSON.stringify(next))).sort(),
  ['apiKey', 'endpoint', 'fallbackModel', 'maxChars', 'model'])
check('maxChars survives', mod.parseConfig(JSON.stringify(next)).maxChars, 1500)
check('fallback survives', mod.parseConfig(JSON.stringify(next)).fallbackModel, 'nvidia/b')

// ---- history
const e1 = mod.makeEntry('Linie', 'Die Linie', { source: 'de', target: 'ru' }, 1)
check('entry pair', e1.pair, 'de-ru')
const h1 = mod.pushHistory([], e1, 20)
check('identical entry not repeated', mod.pushHistory(h1, e1, 20).length, 1)
const h2 = mod.pushHistory(h1, mod.makeEntry('Haus', 'Дом', { source: 'de', target: 'ru' }, 2), 20)
check('newest first', h2[0].source, 'Haus')
check('cap respected', mod.pushHistory(h2, mod.makeEntry('x', 'y', { source: 'de', target: 'ru' }, 3), 2).length, 2)
check('history json parses', mod.parseHistory(JSON.stringify(h2)).length, 2)
check('junk history is empty', mod.parseHistory('nope').length, 0)

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`)
process.exit(failures === 0 ? 0 : 1)