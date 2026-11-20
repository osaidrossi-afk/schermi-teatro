<#
Ponte verso Resolume: gira sul PC della regia, accanto a Resolume.
- Quando dal telecomando si mette in onda una presentazione, scarica le slide in alta risoluzione e le
  carica da solo sul layer delle slide (una clip per slide, nello stesso ordine).
- A ogni comando del telecomando fa partire la clip giusta, nello stesso istante dei monitor dei palchetti.

In Resolume, una volta sola (menu Arena -> Preferences):
  - OSC: «OSC Input» attivo, porta 7000                 (per cambiare slide)
  - Webserver: «Enable Webserver & REST API» attivo, porta 8080   (per caricare le slide da solo)
Uso: doppio clic su «AVVIA PONTE RESOLUME.bat». Al primo avvio chiede il layer delle slide e se lo ricorda.
Si ferma chiudendo la finestra. Funziona con PowerShell di Windows: non serve installare niente.
#>
param(
  [string]$Sito = '',               # dove stanno le pagine degli schermi (serve per l'orologio comune)
  [int]$Layer = 0,                  # layer di Resolume con le slide (0 = chiedi / usa quello salvato)
  [int]$Porta = 7000,               # porta OSC di Resolume
  [int]$PortaWeb = 8080,            # porta del Webserver di Resolume
  [string]$Indirizzo = '127.0.0.1', # Resolume sullo stesso PC
  [string]$Canale = '',             # per le prove: lo stesso ?canale=... delle pagine
  [int]$Durata = 0                  # solo per le prove: si ferma da solo dopo tanti secondi (0 = mai)
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Sito) { Write-Host 'Manca -Sito (l''indirizzo delle pagine degli schermi).' -ForegroundColor Red; exit 1 }
$Sito = $Sito.TrimEnd('/')
$Qui = Split-Path -Parent $MyInvocation.MyCommand.Path
$FileImpostazioni = Join-Path $Qui 'impostazioni.json'
$Archivio = Join-Path $Qui 'presentazioni'

function Scrivi([string]$testo, [string]$colore = 'Gray') { Write-Host ((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $testo) -ForegroundColor $colore }

# layer: quello passato, altrimenti quello salvato, altrimenti si chiede (e si salva)
if ($Layer -le 0 -and (Test-Path $FileImpostazioni)) { try { $Layer = [int](Get-Content $FileImpostazioni -Raw | ConvertFrom-Json).layer } catch { } }
if ($Layer -le 0) {
  $risposta = Read-Host 'Su quale layer di Resolume vanno le slide? (scrivi il numero e premi Invio; solo Invio = 1)'
  $Layer = 1; if ($risposta -match '^\s*(\d+)\s*$') { $Layer = [int]$Matches[1] }
  @{ layer = $Layer } | ConvertTo-Json | Set-Content -Path $FileImpostazioni -Encoding UTF8
  Scrivi "Layer $Layer salvato: per cambiarlo cancella il file impostazioni.json" 'Cyan'
}

$BASE = 'tnfslide7q2m9/'
if ($Canale) { $BASE = "tnfslide7q2m9-$Canale/" }
$SERVER = @(
  @{ url = 'wss://iot.coreflux.cloud:443/mqtt' },
  @{ url = 'wss://public.cloud.shiftr.io:443'; utente = 'public'; parola = 'public' },
  @{ url = 'wss://broker.hivemq.com:8884/mqtt' },
  @{ url = 'wss://test.mosquitto.org:8081/mqtt' }
)
$ID = 'ponte' + [guid]::NewGuid().ToString('N').Substring(0, 6); $script:seq = 0

# ---------------- orologio comune ----------------
# Ogni richiesta al sito dice che ora è sul server (al secondo); ogni risposta restringe la forbice in cui può
# stare lo scarto tra l'orologio di questo PC e quello del server. È lo stesso orologio dei monitor.
$sw = [Diagnostics.Stopwatch]::StartNew()
$origine = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function Locale { return $origine + $sw.Elapsed.TotalMilliseconds }
$script:scarto = 0.0
function Ora { return (Locale) + $script:scarto }
function Sincronizza {
  $basso = [double]::MinValue; $alto = [double]::MaxValue; $buoni = 0
  for ($k = 0; $k -lt 40; $k++) {
    try {
      $req = [Net.HttpWebRequest]::Create("$Sito/versione.txt?s=" + [guid]::NewGuid().ToString('N'))
      $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
      $req.Timeout = 4000
      $t0 = Locale; $res = $req.GetResponse(); $t1 = Locale
      $d = $res.Headers['Date']; $res.Close()
      if ($d -and $k -gt 0) {      # la prima richiesta apre il collegamento e ha tempi lunghi: non si usa
        $s = [DateTimeOffset]::Parse($d).ToUnixTimeMilliseconds()
        $basso = [Math]::Max($basso, $s - $t1); $alto = [Math]::Min($alto, $s + 999 - $t0); $buoni++
      }
    } catch { }
    Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 90)
  }
  if ($buoni -gt 0 -and $basso -le $alto) {
    $script:scarto = ($basso + $alto) / 2
    Scrivi ("Orologio allineato al server (precisione +/- {0} ms)" -f [Math]::Round(($alto - $basso) / 2)) 'Green'
  } else { Scrivi 'Orologio NON allineato: uso quello del PC (possibile sfasamento).' 'Yellow' }
}

# ---------------- regole comuni (uguali a rete.js) ----------------
function Numero($st) { if ($st -and $st.deck) { return [int]$st.deck.n }; return 0 }
function Indice($st, [double]$t) {
  $n = Numero $st
  if (-not $st -or $n -le 0) { return 0 }
  if ($st.modo -eq 'auto') {
    $passo = [Math]::Floor(($t - [double]$st.inizio) / ([double]$st.durata * 1000))
    if ($passo -lt 0) { return ((([int]$st.prima) % $n) + $n) % $n }
    return (((([int]$st.parti) + $passo) % $n) + $n) % $n
  }
  $i = $st.slide
  if ($st.quando -and $t -lt [double]$st.quando) { $i = $st.prima }
  return [Math]::Max(0, [Math]::Min($n - 1, [int]$i))
}
function Nero($st, [double]$t) {
  if (-not $st) { return $false }
  if ($st.neroQuando -and $t -lt [double]$st.neroQuando) { return [bool]$st.neroPrima }
  return [bool]$st.nero
}
function ProssimoCambio($st, [double]$t) {
  if (-not $st) { return $null }
  $c = @()
  if ($st.quando -and $t -lt [double]$st.quando) { $c += [double]$st.quando }
  if ($st.neroQuando -and $t -lt [double]$st.neroQuando) { $c += [double]$st.neroQuando }
  if ($st.modo -eq 'auto') {
    $d = [double]$st.durata * 1000; $passo = [Math]::Floor(($t - [double]$st.inizio) / $d)
    $c += [double]$st.inizio + ($passo + 1) * $d
  }
  if ($c.Count -eq 0) { return $null }
  return ($c | Measure-Object -Minimum).Minimum
}
function NomeSlide([int]$i) { return ('{0:D2}.jpg' -f ($i + 1)) }

# ---------------- Resolume: OSC per cambiare clip, Webserver per caricare i file ----------------
$udp = New-Object Net.Sockets.UdpClient
function Riempi([byte[]]$b) { $l = $b.Length + 1; while ($l % 4) { $l++ }; $r = New-Object byte[] $l; [Array]::Copy($b, $r, $b.Length); return ,$r }
function Osc([string]$percorso, [int]$valore) {
  $a = Riempi ([Text.Encoding]::ASCII.GetBytes($percorso)); $t = Riempi ([Text.Encoding]::ASCII.GetBytes(',i'))
  $v = [BitConverter]::GetBytes([int32]$valore); [Array]::Reverse($v)
  $m = New-Object byte[] ($a.Length + $t.Length + 4)
  [Array]::Copy($a, 0, $m, 0, $a.Length); [Array]::Copy($t, 0, $m, $a.Length, $t.Length); [Array]::Copy($v, 0, $m, $a.Length + $t.Length, 4)
  [void]$udp.Send($m, $m.Length, $Indirizzo, $Porta)
}
$Api = "http://$Indirizzo`:$PortaWeb/api/v1"
function Colonne {
  $c = Invoke-RestMethod -Uri "$Api/composition" -Method Get -TimeoutSec 5
  return @($c.columns).Count
}

# scarica la presentazione e la carica sul layer; restituisce '' se è andato tutto bene, altrimenti il problema
function PreparaDeck($deck) {
  $n = [int]$deck.n; $cartella = Join-Path $Archivio ([string]$deck.id)
  New-Item -ItemType Directory -Force $cartella | Out-Null
  Scrivi ("Presentazione «{0}»: scarico {1} slide per la LEDwall…" -f $deck.titolo, $n) 'Cyan'
  for ($i = 0; $i -lt $n; $i++) {
    $file = Join-Path $cartella (NomeSlide $i)
    if (-not (Test-Path $file)) {
      try { Invoke-WebRequest -Uri ([string]$deck.base + 'l/' + (NomeSlide $i)) -OutFile $file -UseBasicParsing -TimeoutSec 60 }
      catch { return "non riesco a scaricare la slide $($i + 1)" }
    }
    if ($script:ws) { try { Manda ([byte[]]@(0xC0, 0)) } catch { } }   # il collegamento resta vivo durante lo scarico
  }
  # le colonne di Resolume devono essere almeno quante le slide
  try {
    $col = Colonne
    $giri = 0
    while ($col -lt $n -and $giri -lt $n) { Invoke-RestMethod -Uri "$Api/composition/columns/add" -Method Post -TimeoutSec 5 | Out-Null; $col = Colonne; $giri++ }
    if ($col -lt $n) { return "servono $n colonne in Resolume (ora $col)" }
  } catch {
    if ($_.Exception.Message -match 'actively refused|rifiutata|Unable to connect|Impossibile') { return 'attiva il Webserver in Resolume' }
    try { if ((Colonne) -lt $n) { return "servono $n colonne in Resolume" } } catch { return 'attiva il Webserver in Resolume' }
  }
  for ($i = 0; $i -lt $n; $i++) {
    $uri = ([Uri](Join-Path $cartella (NomeSlide $i))).AbsoluteUri
    try { Invoke-RestMethod -Uri "$Api/composition/layers/$Layer/clips/$($i + 1)/open" -Method Post -Body $uri -ContentType 'text/plain' -TimeoutSec 10 | Out-Null }
    catch { return "Resolume non ha caricato la slide $($i + 1) sul layer $Layer" }
  }
  # tengo solo le ultime 5 presentazioni scaricate su questo PC
  Get-ChildItem $Archivio -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Scrivi ("Slide caricate in Resolume sul layer {0}" -f $Layer) 'Green'
  return ''
}

# ---------------- MQTT su WebSocket (minimo) ----------------
$utf8 = New-Object Text.UTF8Encoding($false)
function Lunghezza([int]$n) { $b = New-Object Collections.Generic.List[byte]; do { [int]$x = $n % 128; $n = [int][Math]::Floor($n / 128); if ($n -gt 0) { $x = $x -bor 128 }; $b.Add([byte]$x) } while ($n -gt 0); return ,$b.ToArray() }
function Str([string]$s) { $u = $utf8.GetBytes($s); return ,([byte[]](@([byte]($u.Length -shr 8), [byte]($u.Length -band 255)) + $u)) }
function Pacchetto([int]$tipo, [byte[]]$corpo) { return ,([byte[]](@([byte]$tipo) + (Lunghezza $corpo.Length) + $corpo)) }

$script:ws = $null; $script:buf = New-Object Collections.Generic.List[byte]; $script:ricevi = $null
$script:ultimoRx = 0; $script:ultimoPing = 0
function Manda([byte[]]$b) {
  $seg = New-Object 'ArraySegment[byte]' -ArgumentList @(,$b)
  [void]$script:ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Binary, $true, [Threading.CancellationToken]::None).Wait(5000)
}
function Pubblica([string]$argomento, $oggetto) {
  if (-not $script:ws) { return }
  $script:seq++; $oggetto.id = "$ID.$($script:seq)"; $oggetto.da = $ID
  $corpo = (Str ($BASE + $argomento)) + $utf8.GetBytes(($oggetto | ConvertTo-Json -Compress))
  try { Manda (Pacchetto 0x30 ([byte[]]$corpo)) } catch { }
}
function Collega {
  foreach ($srv in $SERVER) {
    try {
      $w = New-Object Net.WebSockets.ClientWebSocket
      $w.Options.AddSubProtocol('mqtt'); $w.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
      if (-not $w.ConnectAsync([Uri]$srv.url, [Threading.CancellationToken]::None).Wait(8000)) { throw 'tempo scaduto' }
      $script:ws = $w; $script:buf.Clear(); $script:ricevi = $null
      $flag = 2; if ($srv.utente) { $flag = $flag -bor 128 }; if ($srv.parola) { $flag = $flag -bor 64 }
      $corpo = (Str 'MQTT') + [byte[]]@(4, $flag, 0, 90) + (Str ('tns' + $ID + [guid]::NewGuid().ToString('N').Substring(0, 4)))
      if ($srv.utente) { $corpo += (Str $srv.utente) }
      if ($srv.parola) { $corpo += (Str $srv.parola) }
      Manda (Pacchetto 0x10 ([byte[]]$corpo))
      Manda (Pacchetto 0x82 ([byte[]](@([byte]0, [byte]1) + (Str ($BASE + '#')) + @([byte]0))))
      $script:ultimoRx = Locale; $script:ultimoPing = Locale
      Scrivi ('Collegato a ' + ([Uri]$srv.url).Host) 'Green'
      return $true
    } catch { Scrivi ('Server non raggiungibile: ' + ([Uri]$srv.url).Host) 'Yellow' }
  }
  return $false
}
function Leggi {                      # estrae i pacchetti MQTT completi dal buffer e restituisce i messaggi
  $usciti = @()
  while ($script:buf.Count -ge 2) {
    $mol = 1; $rl = 0; $i = 1
    do { if ($i -ge $script:buf.Count) { return $usciti }; $b = $script:buf[$i]; $i++; $rl += ($b -band 127) * $mol; $mol *= 128 } while ($b -band 128)
    if ($script:buf.Count -lt $i + $rl) { return $usciti }
    $tipo = $script:buf[0]; $corpo = $script:buf.GetRange($i, $rl).ToArray(); $script:buf.RemoveRange(0, $i + $rl)
    if (($tipo -shr 4) -eq 3) {
      $tl = ($corpo[0] -shl 8) -bor $corpo[1]; $p = 2 + $tl
      if (($tipo -shr 1) -band 3) { $p += 2 }
      try { $usciti += ($utf8.GetString($corpo, $p, $corpo.Length - $p) | ConvertFrom-Json) } catch { }
    } elseif (($tipo -shr 4) -eq 2 -and $corpo[1] -ne 0) { throw 'collegamento rifiutato dal server' }
  }
  return $usciti
}

# ---------------- avvio ----------------
Scrivi "Ponte Resolume: layer $Layer, OSC $Indirizzo`:$Porta, Webserver $PortaWeb" 'Cyan'
Sincronizza
$stato = $null; $mostrata = -1; $neroOra = $false; $ultimaSinc = Locale
$deckPronto = ''; $errore = ''; $ultimoVivo = 0; $rispondiChi = $false
$segmento = New-Object byte[] 16384
function Vivo { Pubblica 'vivo' @{ k = 'vivo'; ruolo = 'ledwall'; deck = $deckPronto; errore = $errore; slide = $mostrata }; $script:ultimoVivo = Locale }

while ($true) {
  if ($Durata -gt 0 -and $sw.Elapsed.TotalSeconds -gt $Durata) { break }
  try {
    if (-not $script:ws -or $script:ws.State -ne [Net.WebSockets.WebSocketState]::Open) {
      if (-not (Collega)) { Start-Sleep -Seconds 5; continue }
      Vivo
    }
    if (-not $script:ricevi) { $script:ricevi = $script:ws.ReceiveAsync((New-Object 'ArraySegment[byte]' -ArgumentList @(,$segmento)), [Threading.CancellationToken]::None) }

    # quanto aspettare: fino al prossimo cambio (al massimo mezzo secondo), gli ultimi millisecondi «a vista»
    $p = ProssimoCambio $stato (Ora)
    $attesa = 500; if ($p -ne $null) { $attesa = [Math]::Max(0, [Math]::Min(500, $p - (Ora) - 20)) }
    if ($script:ricevi.Wait([int]$attesa)) {
      $r = $script:ricevi.Result; $script:ricevi = $null; $script:ultimoRx = Locale
      if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { $script:ws = $null; continue }
      for ($j = 0; $j -lt $r.Count; $j++) { $script:buf.Add($segmento[$j]) }
      foreach ($m in (Leggi)) {
        if ($m.k -eq 'chi') { $rispondiChi = $true; continue }
        if ($m.k -ne 'stato') { continue }
        if ($stato -and [double]$m.rev -le [double]$stato.rev) { continue }
        $stato = $m
      }
    } elseif ($p -ne $null -and ($p - (Ora)) -lt 25) {
      while ((Ora) -lt $p) { }       # attesa fine: solo gli ultimi millisecondi prima del cambio
    }

    # presentazione nuova in onda: scarica e carica in Resolume (prima di tutto il resto)
    if ($stato -and $stato.deck -and [string]$stato.deck.id -ne $deckPronto) {
      $deckPronto = ''; $errore = ''; Vivo
      $errore = PreparaDeck $stato.deck
      if ($errore) { Scrivi ('PROBLEMA: ' + $errore) 'Red' } else { $deckPronto = [string]$stato.deck.id }
      $mostrata = -1; $neroOra = $false
      Vivo
    }

    if ($stato -and $deckPronto -and (Numero $stato) -gt 0) {
      $t = Ora
      $i = Indice $stato $t
      $n = Nero $stato $t
      if ($n -ne $neroOra) {
        $neroOra = $n
        if ($n) { Osc "/composition/layers/$Layer/clear" 1; Scrivi 'NERO' 'Magenta' }
        else { $mostrata = -1; Scrivi 'riacceso' 'Magenta' }
      }
      if (-not $neroOra -and $i -ne $mostrata) {
        Osc "/composition/layers/$Layer/clips/$($i + 1)/connect" 1
        $mostrata = $i
        $rif = $null
        if ($stato.modo -eq 'auto') { $d = [double]$stato.durata * 1000; $rif = [double]$stato.inizio + [Math]::Floor(($t - [double]$stato.inizio) / $d) * $d }
        elseif ($stato.quando) { $rif = [double]$stato.quando }
        $nota = ''; if ($rif -ne $null -and $t - $rif -lt 1000) { $nota = (' (scarto {0} ms)' -f [Math]::Round($t - $rif)) }
        Scrivi ("slide {0} -> clip {0}{1}" -f ($i + 1), $nota) 'White'
      }
    }

    if ($rispondiChi -or (Locale) - $ultimoVivo -gt 20000) { $rispondiChi = $false; Vivo }
    if ((Locale) - $script:ultimoPing -gt 15000) { Manda ([byte[]]@(0xC0, 0)); $script:ultimoPing = Locale }
    if ((Locale) - $script:ultimoRx -gt 60000) { Scrivi 'Server muto: mi ricollego' 'Yellow'; try { $script:ws.Abort() } catch { }; $script:ws = $null }
    if ((Locale) - $ultimaSinc -gt 600000) { Sincronizza; $ultimaSinc = Locale }
  } catch {
    Scrivi ('Problema: ' + $_.Exception.Message + ' - mi ricollego') 'Yellow'
    try { $script:ws.Abort() } catch { }
    $script:ws = $null; Start-Sleep -Seconds 2
  }
}
Scrivi 'Ponte fermato.' 'Cyan'
