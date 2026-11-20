.pragma library

// Pure helpers for the translator plugin: configuration, the request the
// provider sees, parsing its answer, and the history list. Nothing in this
// file touches QML; the panel and the bar widget import it.

var DEFAULT_ENDPOINT = "https://integrate.api.nvidia.com/v1"
var DEFAULT_MODEL = "nvidia/riva-translate-4b-instruct-v2"
var DEFAULT_FALLBACK_MODEL = "nvidia/nemotron-3.5-lightning-30b-a3b"
var DEFAULT_MAX_CHARS = 2000
var HISTORY_LIMIT = 20
// A reply is untrusted text from a third-party endpoint: it is bounded before
// it reaches layout, the clipboard or the history file.
var MAX_REPLY_CHARS = 8000
// A request that opens a connection and never answers must not wedge the
// panel or keep the token in flight.
var REQUEST_TIMEOUT_MS = 20000
var pendingRequest = null
// Above this many words the input is prose, not a term that needs an article.
var SHORT_PHRASE_WORDS = 3

var LANGUAGES = [
  { code: "ru", short: "RU", name: "Russian" },
  { code: "de", short: "DE", name: "German" },
  { code: "en", short: "EN", name: "English" }
]

// Every target the picker offers. A code outside this table is refused by the
// panel, because the request carries the English name, not the code.
var LANGUAGE_LIST = [
  { code: "af", name: "Afrikaans" }, { code: "ar", name: "Arabic" },
  { code: "bg", name: "Bulgarian" }, { code: "bn", name: "Bengali" },
  { code: "ca", name: "Catalan" }, { code: "cs", name: "Czech" },
  { code: "da", name: "Danish" }, { code: "de", name: "German" },
  { code: "el", name: "Greek" }, { code: "en", name: "English" },
  { code: "es", name: "Spanish" }, { code: "et", name: "Estonian" },
  { code: "fa", name: "Persian" }, { code: "fi", name: "Finnish" },
  { code: "fr", name: "French" }, { code: "he", name: "Hebrew" },
  { code: "hi", name: "Hindi" }, { code: "hr", name: "Croatian" },
  { code: "hu", name: "Hungarian" }, { code: "id", name: "Indonesian" },
  { code: "it", name: "Italian" }, { code: "ja", name: "Japanese" },
  { code: "ka", name: "Georgian" }, { code: "ko", name: "Korean" },
  { code: "lt", name: "Lithuanian" }, { code: "lv", name: "Latvian" },
  { code: "ms", name: "Malay" }, { code: "nl", name: "Dutch" },
  { code: "no", name: "Norwegian" }, { code: "pl", name: "Polish" },
  { code: "pt", name: "Portuguese" }, { code: "ro", name: "Romanian" },
  { code: "ru", name: "Russian" }, { code: "sk", name: "Slovak" },
  { code: "sl", name: "Slovenian" }, { code: "sr", name: "Serbian" },
  { code: "sv", name: "Swedish" }, { code: "th", name: "Thai" },
  { code: "tr", name: "Turkish" }, { code: "uk", name: "Ukrainian" },
  { code: "vi", name: "Vietnamese" }, { code: "zh", name: "Chinese" }
]

// Words that carry a language without a dictionary: enough to tell German
// from English in a sentence, and never applied to Cyrillic.
var GERMAN_MARKERS = [
  " der ", " die ", " das ", " und ", " ist ", " nicht ", " ich ", " sie ",
  " mit ", " für ", " ein ", " eine ", " einen ", " auf ", " wir ", " bitte ",
  " danke ", " haben ", " wird ", " können ", " muss ", " schon ", " noch "
]

function languages() {
  return LANGUAGES
}

function languageList() {
  return LANGUAGE_LIST
}

function languageIndex(code) {
  var value = String(code || "").toLowerCase()
  for (var i = 0; i < LANGUAGE_LIST.length; i++) {
    if (LANGUAGE_LIST[i].code === value) return i
  }
  return -1
}

function isKnownLanguage(code) {
  return languageIndex(code) >= 0
}

// The picker filters on the code and on the English name at once. A code
// prefix is a deliberate address, so those rows come first: typing "fr" must
// not put Afrikaans above French.
function findLanguages(query) {
  var needle = String(query || "").trim().toLowerCase()
  var byCode = []
  var byName = []
  for (var i = 0; i < LANGUAGE_LIST.length; i++) {
    var row = LANGUAGE_LIST[i]
    if (needle === "") byCode.push(row)
    else if (row.code.indexOf(needle) === 0) byCode.push(row)
    else if (row.name.toLowerCase().indexOf(needle) >= 0) byName.push(row)
  }
  return byCode.concat(byName)
}

function languageName(code) {
  var index = languageIndex(code)
  return index >= 0 ? LANGUAGE_LIST[index].name : "English"
}

function languageShort(code) {
  return String(code || "").toUpperCase()
}

// A configured object with every key present, so callers never test for
// undefined. A malformed file yields the defaults plus an empty key, which
// the panel reports as a missing key rather than a crash.
function parseConfig(raw) {
  var parsed = null
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (error) {
    parsed = null
  }
  if (!parsed || typeof parsed !== "object") parsed = {}

  return {
    apiKey: String(parsed.apiKey || ""),
    model: String(parsed.model || DEFAULT_MODEL),
    fallbackModel: parsed.fallbackModel === ""
      ? ""
      : String(parsed.fallbackModel || DEFAULT_FALLBACK_MODEL),
    endpoint: String(parsed.endpoint || DEFAULT_ENDPOINT),
    maxChars: Number(parsed.maxChars) > 0 ? Number(parsed.maxChars) : DEFAULT_MAX_CHARS
  }
}

// A translation NMT wants the language pair as its instruction; a general
// chat model wants a sentence. The apiKey file no longer chooses this: the
// model id does.
function styleForModel(model) {
  return String(model || "").toLowerCase().indexOf("riva-translate") >= 0 ? "pair" : "instruction"
}

// Primary first, then the fallback unless it is the same model or was
// switched off with "fallbackModel": "". A short input on a translation-only
// model is answered the other way round: only an instructional model can add
// the German article, so it goes first and the translation model is the retry.
function models(config, text) {
  var primary = String((config && config.model) || DEFAULT_MODEL)
  var fallback = String((config && config.fallbackModel) || "")
  if (fallback === "" || fallback === primary) return [primary]
  var swap = styleForModel(primary) === "pair"
    && styleForModel(fallback) === "instruction"
    && isShortPhrase(text)
  return swap ? [fallback, primary] : [primary, fallback]
}

// The endpoint may be given as a base ("https://host/v1") or as the full
// chat path; both reach /chat/completions.
function completionsUrl(config) {
  var base = String((config && config.endpoint) || DEFAULT_ENDPOINT)
  if (base.slice(-17) === "/chat/completions") return base
  if (base.slice(-1) === "/") base = base.slice(0, -1)
  return base + "/chat/completions"
}

function modelLabel(model) {
  var value = String(model || "")
  var slash = value.lastIndexOf("/")
  return slash >= 0 ? value.slice(slash + 1) : value
}

// ---- source language ------------------------------------------------------

// Cyrillic is decisive. Everything else is a guess between the two Latin
// languages this widget is set up for, and the guess only steers the pair —
// both directions still translate.
function detectSource(text) {
  var value = String(text || "")
  if (/[\u0400-\u04FF]/.test(value)) return "ru"
  if (/[äöüÄÖÜß]/.test(value)) return "de"

  var lower = " " + value.toLowerCase() + " "
  var hits = 0
  for (var i = 0; i < GERMAN_MARKERS.length; i++) {
    if (lower.indexOf(GERMAN_MARKERS[i]) >= 0) hits++
    if (hits >= 2) return "de"
  }
  return "en"
}

// The pair actually sent. Asking for the language the text is already in is
// a dead end, so it flips to the other one: Russian text goes to German,
// anything else to Russian.
function resolvePair(text, targetCode) {
  var source = detectSource(text)
  var target = String(targetCode || "ru")
  if (source === target) target = source === "ru" ? "de" : "ru"
  return { source: source, target: target }
}

function pairCode(source, target) {
  return String(source) + "-" + String(target)
}

// ---- request and reply ----------------------------------------------------

function instructionPrompt(targetCode) {
  var prompt = "You are a translation engine. Translate the user's text into "
    + languageName(targetCode) + "."
    + " Detect the source language yourself and translate from it."
    + " Keep the meaning, the register and the layout of the original."
  if (String(targetCode) === "de") {
    prompt += " A German noun carries its definite article and a capital letter"
      + " whenever the text is one word or a short noun phrase:"
      + " 'Linie' → 'Die Linie', 'Tisch' → 'Der Tisch', 'Buch' → 'Das Buch'."
  }
  return prompt
    + " Output the translation only: no explanations, no notes, no quotes, no preamble."
}

// One word or a short noun phrase: the case where the German answer has to
// carry an article, and where a translation-only model cannot be asked.
function isShortPhrase(text) {
  var words = String(text === undefined || text === null ? "" : text)
    .split(/[^0-9A-Za-z\u00C0-\u024F\u0400-\u04FF]+/)
  var count = 0
  for (var i = 0; i < words.length; i++) if (words[i] !== "") count++
  return count > 0 && count <= SHORT_PHRASE_WORDS
}

// A stress mark over a Cyrillic vowel is a reading aid, not a letter. It only
// misleads the model and the word count.
function stripStress(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/([\u0400-\u04FF])\u0301/g, "$1")
}

function requestBody(config, model, text, pair) {
  var system = styleForModel(model) === "pair"
    ? pairCode(pair.source, pair.target)
    : instructionPrompt(pair.target)

  return JSON.stringify({
    model: model,
    temperature: 0.1,
    max_tokens: 2048,
    stream: false,
    // Thinking output dominates the latency and can fill max_tokens before the
    // translation starts: 8.3 s with thinking, 0.5 s without, for one sentence.
    chat_template_kwargs: { enable_thinking: false },
    messages: [
      { role: "system", content: system },
      { role: "user", content: String(text) }
    ]
  })
}

// POST via the QML XMLHttpRequest. It lives here, in a library, so qmllint
// sees no unqualified XHR use in the QML files it checks.
//
// A refused or empty answer from the primary model is retried once on the
// fallback; the result says which model answered, so the panel can show it.
function send(config, text, pair, onReply) {
  var chain = models(config, text)
  var url = completionsUrl(config)

  function attempt(index) {
    // One request in flight: a newer ask, or a panel that closed, must not
    // leave the previous connection pending with the token in its header.
    if (pendingRequest) {
      try { pendingRequest.abort() } catch (error) { }
      pendingRequest = null
    }
    var model = chain[index]
    var request = new XMLHttpRequest()
    request.timeout = REQUEST_TIMEOUT_MS
    request.open("POST", url, true)
    request.setRequestHeader("Content-Type", "application/json")
    request.setRequestHeader("Accept", "application/json")
    request.setRequestHeader("Authorization", "Bearer " + String((config && config.apiKey) || ""))
    request.onreadystatechange = function() {
      if (request.readyState !== 4) return
      if (pendingRequest !== request) return
      pendingRequest = null
      var reply = parseReply(request.status, request.responseText)
      if (!reply.ok && index + 1 < chain.length) {
        attempt(index + 1)
        return
      }
      onReply({
        ok: reply.ok,
        text: reply.ok ? reply.text : "",
        error: reply.ok ? "" : reply.error,
        truncated: reply.ok && reply.truncated === true,
        model: model,
        fallback: index > 0
      })
    }
    request.ontimeout = function() {
      if (pendingRequest !== request) return
      pendingRequest = null
      onReply({
        ok: false,
        text: "",
        error: "The provider did not answer within " + Math.round(REQUEST_TIMEOUT_MS / 1000) + " s",
        model: model,
        fallback: index > 0
      })
    }
    pendingRequest = request
    request.send(requestBody(config, model, text, pair))
  }

  attempt(0)
}

// Called when the panel closes: nothing of ours stays in flight afterwards.
function cancel() {
  if (!pendingRequest) return
  try { pendingRequest.abort() } catch (error) { }
  pendingRequest = null
}

function errorFromBody(status, body) {
  var detail = ""
  try {
    var parsed = JSON.parse(String(body || ""))
    detail = String((parsed.error && (parsed.error.message || parsed.error)) || parsed.detail || "")
  } catch (error) {
    detail = ""
  }
  if (detail === "") detail = String(body || "").slice(0, 160)
  if (status === 401 || status === 403) return "Key rejected (" + status + ")"
  if (status === 429) return "Rate limit, try again later (429)"
  if (status === 404) return "Model or address not found (404)"
  if (status === 0) return "No connection to the provider"
  return "Error " + status + ": " + detail
}

// { ok: true, text } or { ok: false, error }.
function parseReply(status, body) {
  if (status !== 200) return { ok: false, error: errorFromBody(status, body) }

  var parsed = null
  try {
    parsed = JSON.parse(String(body || ""))
  } catch (error) {
    return { ok: false, error: "Response is not valid JSON" }
  }

  var choices = parsed && parsed.choices
  if (!choices || choices.length === 0) return { ok: false, error: "Empty reply from the model" }

  var message = choices[0].message || {}
  var text = String(message.content || "")
  if (text === "") text = String(choices[0].text || "")
  text = stripNoise(text)
  if (text === "") return { ok: false, error: "The model returned an empty translation" }
  if (text.length > MAX_REPLY_CHARS) {
    return { ok: true, text: text.slice(0, MAX_REPLY_CHARS), truncated: true }
  }
  return { ok: true, text: text }
}

// A markdown fence, or the pair code echoed on its own line ahead of the
// translation, is noise the model adds despite the instruction.
function stripNoise(text) {
  var value = String(text || "").replace(/^\s+|\s+$/g, "")
  if (value.slice(0, 3) === "```") {
    var breakAt = value.indexOf("\n")
    value = breakAt < 0 ? value.slice(3) : value.slice(breakAt + 1)
    value = value.replace(/```\s*$/, "")
  }
  return value.replace(/^\s+|\s+$/g, "")
}

// One line, no runs of whitespace, cut at `limit` characters.
function cleanText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  text = stripStress(text)
  var cap = Number(limit) > 0 ? Number(limit) : DEFAULT_MAX_CHARS
  if (text.length > cap) text = text.slice(0, cap)
  return text
}

function preview(value, limit) {
  var flat = String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ")
  var text = cleanText(flat, limit || 80)
  if (flat.length > text.length) text += "…"
  return text
}

// ---- history --------------------------------------------------------------

function makeEntry(source, translation, pair, stamp) {
  return {
    source: String(source),
    translation: String(translation),
    pair: pairCode(pair.source, pair.target),
    target: String(pair.target),
    stamp: Number(stamp) || 0
  }
}

function parseHistory(raw) {
  var parsed = null
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (error) {
    parsed = null
  }
  if (!parsed || !(parsed instanceof Array)) return []
  var list = []
  for (var i = 0; i < parsed.length && list.length < HISTORY_LIMIT; i++) {
    var row = parsed[i]
    if (!row || typeof row !== "object") continue
    if (String(row.source || "") === "" || String(row.translation || "") === "") continue
    list.push({
      source: String(row.source),
      translation: String(row.translation),
      pair: String(row.pair || ""),
      target: String(row.target || "ru"),
      stamp: Number(row.stamp) || 0
    })
  }
  return list
}

// Newest first, an identical pair moved to the top rather than repeated.
function pushHistory(list, entry, limit) {
  var cap = Number(limit) > 0 ? Number(limit) : HISTORY_LIMIT
  var next = [entry]
  var current = list instanceof Array ? list : []
  for (var i = 0; i < current.length && next.length < cap; i++) {
    var row = current[i]
    if (String(row.source) === String(entry.source)
      && String(row.translation) === String(entry.translation)) continue
    next.push(row)
  }
  return next
}
