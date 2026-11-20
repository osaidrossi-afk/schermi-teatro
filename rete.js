// Collegamento in tempo reale tra telecomando, monitor dei palchetti e ponte verso Resolume.
// Stessa tecnica dei giochi sugli schermi esterni (Progetti\schermo-teatro\rete.js): un collegamento sempre
// aperto (MQTT su WebSocket) verso più server pubblici in parallelo. Ogni messaggio parte su tutti e chi lo
// riceve tiene la prima copia: se un server cade lavorano gli altri. Dalla rete del teatro passano solo i
// server sulla porta 443.
// Qui c'è anche l'orologio comune: tutti gli schermi cambiano slide nello stesso istante dell'ora del server.

var RETE = (function () {
  // Argomento riservato a queste slide: diverso da quello dei giochi, non si toccano a vicenda.
  // Per le prove: ?canale=prova usa un argomento a parte e non tocca gli schermi veri.
  var BASE = 'tnfslide7q2m9/';
  var canale = (location.search.match(/[?&]canale=([a-z0-9]{1,12})/) || [])[1];
  if (canale) BASE = 'tnfslide7q2m9-' + canale + '/';
  var SERVER = [
    { url: 'wss://iot.coreflux.cloud:443/mqtt' },
    { url: 'wss://public.cloud.shiftr.io:443', utente: 'public', parola: 'public' },
    { url: 'wss://broker.hivemq.com:8884/mqtt' },
    { url: 'wss://test.mosquitto.org:8081/mqtt' }
  ];
  var solo = (location.search.match(/[?&]solo=([^&]+)/) || [])[1];     // ?solo=coreflux,shiftr simula la rete del teatro
  if (solo) SERVER = SERVER.filter(function (s) { return solo.split(',').some(function (x) { return s.url.indexOf(x) >= 0; }); });
  var ID = Math.random().toString(36).slice(2, 10), seq = 0;
  var visti = {}, ordineVisti = [], ascoltatori = [], conn = [], inAttesa = {};

  // ---------- MQTT 3.1.1 minimo (connessione, iscrizione, pubblicazione QoS 0) ----------
  var enc = new TextEncoder(), dec = new TextDecoder();
  function lunghezza(n) { var b = []; do { var x = n % 128; n = Math.floor(n / 128); if (n > 0) x |= 128; b.push(x); } while (n > 0); return b; }
  function str(s) { var u = enc.encode(s); return [u.length >> 8, u.length & 255].concat(Array.from(u)); }
  function pacchetto(tipo, corpo) { return new Uint8Array([tipo].concat(lunghezza(corpo.length), corpo)); }

  function Connessione(srv) {
    var ws = null, buf = new Uint8Array(0), ping = null, pronta = false, attesa = 1000, ultimoRx = 0;
    this.url = srv.url;
    this.pronta = function () { return pronta; };
    function apri() {
      buf = new Uint8Array(0); ultimoRx = Date.now();
      try { ws = new WebSocket(srv.url, 'mqtt'); } catch (e) { return riprova(); }
      ws.binaryType = 'arraybuffer';
      ws.onopen = function () {
        var cid = 'tns' + ID + Math.random().toString(36).slice(2, 6);
        var flag = 2 | (srv.utente ? 128 : 0) | (srv.parola ? 64 : 0), corpo = str('MQTT').concat([4, flag, 0, 30], str(cid));
        if (srv.utente) corpo = corpo.concat(str(srv.utente));
        if (srv.parola) corpo = corpo.concat(str(srv.parola));
        ws.send(pacchetto(0x10, corpo));
      };
      ws.onmessage = function (e) {
        ultimoRx = Date.now();
        var nuovo = new Uint8Array(e.data), t = new Uint8Array(buf.length + nuovo.length);
        t.set(buf); t.set(nuovo, buf.length); buf = t; leggi();
      };
      ws.onclose = function () { pronta = false; clearInterval(ping); riprova(); };
      ws.onerror = function () { try { ws.close(); } catch (e) {} };
    }
    function riprova() { setTimeout(apri, attesa); attesa = Math.min(15000, attesa * 2); }
    function leggi() {
      while (buf.length >= 2) {
        var mol = 1, rl = 0, i = 1, b;
        do { if (i >= buf.length) return; b = buf[i++]; rl += (b & 127) * mol; mol *= 128; } while (b & 128);
        if (buf.length < i + rl) return;
        var tipo = buf[0], corpo = buf.subarray(i, i + rl);
        buf = buf.slice(i + rl);
        if ((tipo >> 4) === 2) {                       // CONNACK
          if (corpo[1] !== 0) { try { ws.close(); } catch (e) {} return; }
          pronta = true; attesa = 1000;
          ws.send(pacchetto(0x82, [0, 1].concat(str(BASE + '#'), [0])));
          ping = setInterval(function () {             // un server che non risponde più ai ping si chiude e si riapre
            if (Date.now() - ultimoRx > 45000) { pronta = false; clearInterval(ping); var w = ws; try { w.onclose = w.onmessage = w.onerror = null; w.close(); } catch (e) {} riprova(); return; }
            try { ws.send(new Uint8Array([0xC0, 0])); } catch (e) {}
          }, 15000);
          svuota();
        } else if ((tipo >> 4) === 3) {                // PUBLISH
          var tl = (corpo[0] << 8) | corpo[1], argomento = dec.decode(corpo.subarray(2, 2 + tl)), p = 2 + tl;
          if ((tipo >> 1) & 3) p += 2;
          arriva(argomento.slice(BASE.length), dec.decode(corpo.subarray(p)));
        }
      }
    }
    this.manda = function (argomento, testo, trattieni) {
      if (!pronta) return false;
      var corpo = str(BASE + argomento).concat(Array.from(enc.encode(testo)));
      try { ws.send(pacchetto(0x30 | (trattieni ? 1 : 0), corpo)); return true; } catch (e) { return false; }
    };
    apri();
  }

  function arriva(argomento, testo) {
    if (!testo) return;
    var m; try { m = JSON.parse(testo); } catch (e) { return; }
    if (!m || typeof m !== 'object' || typeof m.k !== 'string') return;
    var chiave = m.id || testo;
    if (visti[chiave]) return;                         // stessa copia arrivata da un altro server
    visti[chiave] = 1; ordineVisti.push(chiave);
    if (ordineVisti.length > 3000) delete visti[ordineVisti.shift()];
    m.argomento = argomento;
    ascoltatori.forEach(function (f) { try { f(m); } catch (e) { if (window.console) console.error(e); } });
  }

  function svuota() {          // appena c'è un collegamento parte l'ultimo messaggio rimasto indietro, per argomento
    Object.keys(inAttesa).forEach(function (arg) {
      var a = inAttesa[arg], ok = false;
      conn.forEach(function (c) { ok = c.manda(arg, a[0], a[1]) || ok; });
      if (ok) delete inAttesa[arg];
    });
  }
  function collega() { if (!conn.length) SERVER.forEach(function (u) { conn.push(new Connessione(u)); }); }
  // argomenti: 'stato' = cosa devono mostrare gli schermi (trattenuto: chi si accende lo riceve subito)
  //            'vivo'  = ogni schermo dice ogni tanto che è acceso e cosa mostra
  function manda(m, argomento, trattieni) {
    m.id = ID + '.' + (++seq); m.da = ID;
    var t = JSON.stringify(m), ok = false;
    conn.forEach(function (c) { ok = c.manda(argomento, t, trattieni) || ok; });
    if (!ok && trattieni) inAttesa[argomento] = [t, trattieni];
    arriva(argomento, t);                              // anche il mittente vede il proprio messaggio, subito
    return ok;
  }
  function collegato() { return conn.some(function (c) { return c.pronta(); }); }
  function server() { return conn.map(function (c) { return c.url.split('/')[2].split(':')[0] + (c.pronta() ? ' ok' : ' no'); }); }
  return { ID: ID, collega: collega, manda: manda, ascolta: function (f) { ascoltatori.push(f); }, collegato: collegato, server: server };
})();

// ---------- orologio comune ----------
// L'ora del server arriva al secondo: si cerca l'istante in cui il secondo scatta.
// 1) una serie di richieste trova lo scatto all'incirca; 2) due raffiche fitte, a cavallo dello scatto previsto, lo stringono.
// I tempi si prendono dal registro della rete del browser (Resource Timing), non da quando il codice riesce a girare:
// su un processore lento (la TV) il codice arriva in ritardo e l'orologio sbaglierebbe di decimi di secondo.
var scarto = 0;
function ora() { return Date.now() + scarto; }
function sincronizza() {
  var campioni = [], stima = null, larghezza = Infinity;
  function uno() {
    var url = 'versione.txt?s=' + Math.random(), l0 = Date.now(), p0 = performance.now();
    return fetch(url, { cache: 'no-store' }).then(function (r) {
      var d = r.headers.get('date'), mezzo = (p0 + performance.now()) / 2;
      try {
        var e = performance.getEntriesByName(new URL(url, location.href).href).pop();
        if (e && e.requestStart > 0 && e.responseStart >= e.requestStart) mezzo = (e.requestStart + e.responseStart) / 2;
      } catch (x) {}
      if (d) campioni.push({ locale: l0 + (mezzo - p0), server: new Date(d).getTime() });
      return r.text();
    }).catch(function () {});
  }
  function calcola() {
    campioni.sort(function (a, b) { return a.locale - b.locale; });
    for (var i = 1; i < campioni.length; i++) {
      var a = campioni[i - 1], b = campioni[i];
      if (b.server > a.server && b.locale - a.locale < larghezza) { larghezza = b.locale - a.locale; stima = b.server - (a.locale + b.locale) / 2; }
    }
    if (stima !== null) scarto = stima;
  }
  function serie(n) { return n <= 0 ? Promise.resolve() : uno().then(function () { return new Promise(function (ok) { setTimeout(ok, 45); }); }).then(function () { return serie(n - 1); }); }
  function raffica() {
    if (stima === null) return Promise.resolve();
    var adesso = Date.now(), scatto = Math.ceil((adesso + stima + 150) / 1000) * 1000 - stima, attese = [];
    return new Promise(function (fatto) {
      setTimeout(function () {
        for (var k = 0; k < 12; k++) attese.push(new Promise(function (ok) { setTimeout(function () { uno().then(ok); }, k * 15); }));
        Promise.all(attese).then(fatto);
      }, Math.max(0, scatto - 90 - adesso));
    });
  }
  return serie(16).then(function () { calcola(); return raffica(); }).then(function () { calcola(); return raffica(); }).then(function () {
    calcola();
    if (stima === null && campioni.length) scarto = campioni[0].server + 500 - campioni[0].locale;
    try { performance.clearResourceTimings(); } catch (x) {}
    return larghezza;
  }).catch(function () { return Infinity; });
}

// ---------- regole comuni: quale slide va mostrata in un certo istante ----------
// Lo stato lo decide il telecomando ed è uguale per tutti:
//   deck: { id, n, base, titolo }          → la presentazione in onda: n slide, immagini sotto «base»
//                                           (base + 'm/01.jpg' monitor, 'l/01.jpg' LEDwall, 't/01.jpg' miniature)
//   modo 'mano': { slide, prima, quando }  → fino a «quando» si vede «prima», da «quando» si vede «slide»
//   modo 'auto': { parti, inizio, durata } → dalla slide «parti», all'istante «inizio», una slide ogni «durata» secondi, in giro
//   nero: true/false, con il suo «quando» (schermo nero, per le pause)
// Ogni schermo calcola da sé: in automatico non serve nessun messaggio a ogni cambio, e se la rete cade per un
// momento gli schermi continuano comunque insieme.
var SLIDE = {
  numero: function (st) { return st && st.deck ? (st.deck.n | 0) : 0; },
  immagine: function (deck, tipo, i) { return deck.base + tipo + '/' + (i + 1 < 10 ? '0' : '') + (i + 1) + '.jpg'; },
  indice: function (st, t) {
    var n = SLIDE.numero(st);
    if (!st || !n) return 0;
    if (st.modo === 'auto') {
      var passo = Math.floor((t - st.inizio) / (st.durata * 1000));
      if (passo < 0) return ((st.prima | 0) % n + n) % n;
      return (((st.parti | 0) + passo) % n + n) % n;
    }
    var i = (st.quando && t < st.quando) ? st.prima : st.slide;
    return Math.max(0, Math.min(n - 1, i | 0));
  },
  prossimoCambio: function (st, t) {             // l'istante del prossimo cambio, per svegliarsi giusto in tempo
    if (!st) return null;
    var c = [];
    if (st.quando && t < st.quando) c.push(st.quando);
    if (st.neroQuando && t < st.neroQuando) c.push(st.neroQuando);
    if (st.modo === 'auto') {
      var d = st.durata * 1000, passo = Math.floor((t - st.inizio) / d);
      c.push(st.inizio + (passo + 1) * d);
    }
    return c.length ? Math.min.apply(null, c) : null;
  },
  nero: function (st, t) {
    if (!st) return false;
    if (st.neroQuando && t < st.neroQuando) return !!st.neroPrima;
    return !!st.nero;
  }
};
