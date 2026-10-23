#!/usr/bin/env python3
"""Local Gemini approval service for FvgGold MT5 EA. Standard library only."""
from __future__ import annotations
import json, os, time, threading, logging, urllib.request, urllib.error, secrets, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from datetime import datetime, timezone
from typing import Any

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def load_env(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path, 'r', encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k and k not in os.environ:
                os.environ[k] = v

load_env(os.path.join(BASE_DIR, '.env'))
logging.basicConfig(level=getattr(logging, os.getenv('LOG_LEVEL','INFO').upper(), logging.INFO),
                    format='%(asctime)s %(levelname)s %(message)s',
                    handlers=[logging.StreamHandler(), logging.FileHandler(os.path.join(BASE_DIR,'ai_service.log'), encoding='utf-8')])
log = logging.getLogger('fvg-ai')

HOST = os.getenv('SERVICE_HOST', '127.0.0.1')
PORT = int(os.getenv('SERVICE_PORT', '8787'))
SERVICE_TOKEN = os.getenv('AI_SERVICE_TOKEN', '').strip()
MODEL = os.getenv('GEMINI_MODEL', 'gemini-2.5-flash').strip()
MIN_CONFIDENCE = float(os.getenv('MIN_AI_CONFIDENCE', '0.70'))
MAX_RISK_PERCENT = float(os.getenv('MAX_RISK_PERCENT', '0.25'))
MAX_SPREAD_POINTS = float(os.getenv('MAX_SPREAD_POINTS', '80'))
REQUEST_TIMEOUT = int(os.getenv('GEMINI_TIMEOUT_SECONDS', '18'))
KEY_COOLDOWN = int(os.getenv('KEY_COOLDOWN_SECONDS', '90'))
TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN', '').strip()
ALLOWED_CHAT_IDS = {x.strip() for x in os.getenv('TELEGRAM_ALLOWED_CHAT_IDS','').split(',') if x.strip()}
GEMINI_KEYS = [x.strip() for x in os.getenv('GEMINI_API_KEYS','').split(',') if x.strip() and not x.strip().startswith('REPLACE_')]

if not SERVICE_TOKEN or SERVICE_TOKEN in ('CHANGE_ME', 'CHANGE_ME_TO_MATCH_ENV', 'replace-with-a-long-random-secret'):
    log.error('AI_SERVICE_TOKEN is missing or still a placeholder. Set it in .env before starting.')
    raise SystemExit('Configure AI_SERVICE_TOKEN in .env first.')
if len(SERVICE_TOKEN) < 32:
    log.warning('AI_SERVICE_TOKEN should be at least 32 characters long.')

lock = threading.RLock()
state = {
    'paused': False, 'stopped': False, 'started_at': time.time(),
    'last_heartbeat': None, 'heartbeat': {}, 'last_decision': {},
    'last_analysis': {}, 'last_positions': None, 'key_index': 0,
    'key_cooldowns': {}, 'key_last_used': None, 'last_error': None,
}

# --- HTTP and response helpers -------------------------------------------------
def json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False).encode('utf-8')

def telegram_send(text: str) -> None:
    if not TELEGRAM_TOKEN or not ALLOWED_CHAT_IDS:
        return
    for chat_id in ALLOWED_CHAT_IDS:
        try:
            payload = json_bytes({'chat_id': chat_id, 'text': text[:3900], 'disable_web_page_preview': True})
            req = urllib.request.Request(f'https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage', data=payload,
                                         headers={'Content-Type':'application/json'}, method='POST')
            with urllib.request.urlopen(req, timeout=8) as r:
                r.read()
        except Exception as exc:
            log.warning('Telegram send failed (%s)', type(exc).__name__)

def active_state() -> bool:
    with lock:
        return bool(GEMINI_KEYS) and not state['paused'] and not state['stopped']

def status_payload() -> dict:
    with lock:
        hb = state['heartbeat'] or {}
        age = None if not state['last_heartbeat'] else max(0, int(time.time()-state['last_heartbeat']))
        active = bool(GEMINI_KEYS) and not state['paused'] and not state['stopped']
        status = 'no_gemini_keys' if not GEMINI_KEYS else ('active' if active else ('stopped' if state['stopped'] else 'paused'))
        return {'ok': True, 'active': active, 'status': status, 'model': MODEL,
                'configured_keys': len(GEMINI_KEYS), 'heartbeat_age_seconds': age,
                'mt5_connected_recently': age is not None and age <= 45,
                'last_decision': state['last_decision'], 'heartbeat': hb,
                'last_error': state['last_error']}

def request_json(url: str, payload: dict, timeout: int, headers: dict | None = None) -> dict:
    data = json_bytes(payload)
    h = {'Content-Type': 'application/json'}
    if headers: h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method='POST')
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode('utf-8'))

def extract_gemini_text(result: dict) -> str:
    candidates = result.get('candidates') or []
    if not candidates:
        raise ValueError('Gemini returned no candidates')
    parts = (((candidates[0].get('content') or {}).get('parts')) or [])
    text = ''.join(str(p.get('text','')) for p in parts if isinstance(p,dict))
    if not text:
        raise ValueError('Gemini returned an empty response')
    text = re.sub(r'^\s*```(?:json)?\s*|\s*```\s*$', '', text, flags=re.I)
    return text.strip()

def get_key_order() -> list[int]:
    now = time.time()
    with lock:
        n = len(GEMINI_KEYS)
        if not n: return []
        start = state['key_index'] % n
        order = [(start+i) % n for i in range(n)]
        return [i for i in order if state['key_cooldowns'].get(str(i), 0) <= now]

def cooldown_key(index: int, seconds: int, reason: str) -> None:
    with lock:
        state['key_cooldowns'][str(index)] = time.time()+seconds
        state['last_error'] = reason
        state['key_index'] = (index+1) % max(1,len(GEMINI_KEYS))

def call_gemini(candidate: dict) -> dict:
    if not GEMINI_KEYS:
        raise RuntimeError('No Gemini API keys configured')
    system = (
      'You are a conservative market-setup reviewer for an automated XAUUSD trading system. '
      'You are not a guaranteed-profitable trader. Review only the supplied candidate and closed-candle arrays; do not invent prices, '
      'news, candles, or missing indicators. The local EA has already found an FVG candidate. '
      'Your job is to approve that same direction only when evidence is coherent; otherwise WAIT. '
      'Never reverse the candidate direction. Prefer WAIT when information is incomplete or conditions are weak. '
      'Do not recommend increasing risk, averaging down, martingale, or removing a stop loss. '
      'Return ONLY JSON with keys decision (BUY, SELL, or WAIT), confidence (number 0 to 1), reason (short string), '
      'and risk_notes (short string). Confidence expresses confidence in setup quality, not probability of profit.'
    )
    user = {'candidate': candidate, 'rules': {
        'minimum_fvg_score': 65, 'max_spread_points': MAX_SPREAD_POINTS,
        'max_risk_percent': MAX_RISK_PERCENT, 'minimum_reward_to_risk': 1.5,
        'reject_if_daily_loss_limit_hit': True,
        'must_match_candidate_direction': True,
        'be_conservative_and_return_WAIT_if_uncertain': True
    }}
    body = {
      'systemInstruction': {'parts':[{'text':system}]},
      'contents':[{'role':'user','parts':[{'text':json.dumps(user, separators=(',',':'))}]}],
      'generationConfig': {'temperature':0.1, 'responseMimeType':'application/json',
                           'responseSchema': {'type':'OBJECT','properties':{
                             'decision':{'type':'STRING','enum':['BUY','SELL','WAIT']},
                             'confidence':{'type':'NUMBER'}, 'reason':{'type':'STRING'}, 'risk_notes':{'type':'STRING'}
                           },'required':['decision','confidence','reason','risk_notes']}}
    }
    errors = []
    order = get_key_order()
    if not order:
        raise RuntimeError('All configured Gemini keys are cooling down or no keys are configured')
    for idx in order:
        key = GEMINI_KEYS[idx]
        url = f'https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent?key={key}'
        try:
            result = request_json(url, body, REQUEST_TIMEOUT)
            text = extract_gemini_text(result)
            parsed = json.loads(text)
            decision = str(parsed.get('decision','WAIT')).upper()
            confidence = float(parsed.get('confidence',0))
            if decision not in ('BUY','SELL','WAIT') or not 0 <= confidence <= 1:
                raise ValueError('Gemini response failed schema validation')
            with lock:
                state['key_index'] = (idx+1) % len(GEMINI_KEYS)
                state['key_last_used'] = idx+1
                state['last_error'] = None
            return {'decision':decision,'confidence':confidence,
                    'reason':str(parsed.get('reason','No reason provided'))[:500],
                    'risk_notes':str(parsed.get('risk_notes',''))[:500], 'key_slot':idx+1}
        except urllib.error.HTTPError as exc:
            code = exc.code
            try: detail = exc.read(1000).decode('utf-8','ignore')
            except Exception: detail = ''
            errors.append(f'key-slot-{idx+1}:HTTP-{code}')
            # Invalid key / quota / rate limit: skip this key for a while; never log URL/key.
            cooldown_key(idx, 900 if code in (400,401,403) else KEY_COOLDOWN, f'Gemini HTTP {code}')
            log.warning('Gemini key slot %s failed HTTP %s', idx+1, code)
        except Exception as exc:
            errors.append(f'key-slot-{idx+1}:{type(exc).__name__}')
            cooldown_key(idx, KEY_COOLDOWN, type(exc).__name__)
            log.warning('Gemini key slot %s failed: %s', idx+1, type(exc).__name__)
    raise RuntimeError('Gemini unavailable; tried eligible keys: ' + ','.join(errors))

def validate_candidate(c: dict) -> str | None:
    required = ['symbol','direction','entry','stop_loss','take_profit','lot','fvg_score','spread_points','equity']
    for k in required:
        if k not in c: return f'Missing required field: {k}'
    if str(c['symbol']).upper().find('XAUUSD') < 0:
        return 'This build is configured for gold symbols containing XAUUSD only'
    direction = str(c['direction']).upper()
    if direction not in ('BUY','SELL'): return 'Invalid direction'
    try:
        entry, sl, tp = float(c['entry']), float(c['stop_loss']), float(c['take_profit'])
        lot, score, spread = float(c['lot']), float(c['fvg_score']), float(c['spread_points'])
        equity = float(c['equity'])
    except (TypeError, ValueError): return 'Invalid numeric input'
    if min(entry, sl, tp, lot, equity) <= 0: return 'Non-positive trade parameter'
    if direction == 'BUY' and not sl < entry < tp: return 'BUY stop/entry/target geometry invalid'
    if direction == 'SELL' and not tp < entry < sl: return 'SELL stop/entry/target geometry invalid'
    risk = abs(entry-sl); reward = abs(tp-entry)
    if risk <= 0 or reward/risk < 1.5 - 1e-6: return 'Reward-to-risk below conservative minimum 1.5'
    if score < 65: return 'FVG score below conservative minimum 65'
    if spread > min(MAX_SPREAD_POINTS, float(c.get('max_spread_points', MAX_SPREAD_POINTS))): return 'Spread above configured maximum'
    daily_limit = float(c.get('daily_loss_limit',0) or 0)
    if daily_limit > 0 and float(c.get('daily_pl',0) or 0) <= -daily_limit: return 'Daily loss limit reached'
    risk_pct = float(c.get('risk_percent',0) or 0)
    if risk_pct > MAX_RISK_PERCENT + 1e-6: return 'Requested risk percentage exceeds service maximum'
    if not active_state(): return 'Trading service paused/stopped'
    return None

# --- Telegram polling ---------------------------------------------------------
def telegram_loop() -> None:
    if not TELEGRAM_TOKEN:
        log.info('Telegram bot not configured; Telegram controls disabled.')
        return
    if not ALLOWED_CHAT_IDS:
        log.warning('Telegram token is set but TELEGRAM_ALLOWED_CHAT_IDS is empty; commands are disabled for safety.')
        return
    offset = 0
    while True:
        try:
            url = f'https://api.telegram.org/bot{TELEGRAM_TOKEN}/getUpdates?timeout=20&offset={offset}'
            req = urllib.request.Request(url, headers={'User-Agent':'FvgGold-AI/1.0'})
            with urllib.request.urlopen(req, timeout=25) as r: data = json.loads(r.read().decode('utf-8'))
            for update in data.get('result',[]):
                offset = max(offset, int(update.get('update_id',0))+1)
                msg = update.get('message') or update.get('edited_message') or {}
                chat = str((msg.get('chat') or {}).get('id',''))
                if chat not in ALLOWED_CHAT_IDS: continue
                command = (msg.get('text') or '').strip().split()[0].lower().split('@')[0] if (msg.get('text') or '').strip() else ''
                reply = None
                if command in ('/start','/help'):
                    reply = ('FvgGold AI controls\n/status - service and MT5 heartbeat\n/analysis - last AI decision\n/positions - last reported position count\n'
                             '/dailyreport - account snapshot\n/pause - block new entries and cancel pending EA orders\n'
                             '/resume - re-enable after checks\n/stop - emergency stop for new entries')
                elif command == '/status':
                    st=status_payload(); hb=st.get('heartbeat') or {}
                    reply=f"Status: {st['status']}\nModel: {MODEL}\nGemini key slots: {st['configured_keys']}\nMT5 heartbeat age: {st['heartbeat_age_seconds']}s\nSymbol: {hb.get('symbol','unknown')}\nBalance: {hb.get('balance','n/a')}\nEquity: {hb.get('equity','n/a')}"
                elif command == '/analysis':
                    with lock: a=dict(state['last_analysis'])
                    reply = ('No AI review yet. The EA sends a review only when an FVG candidate is found.' if not a else
                             f"Last review: {a.get('decision')} ({a.get('confidence',0):.2f})\n{a.get('reason','')}\nRisk: {a.get('risk_notes','')}")
                elif command == '/positions':
                    with lock: hb=dict(state['heartbeat'])
                    reply=f"Symbol: {hb.get('symbol','unknown')}\nOpen positions: {hb.get('positions','unknown')}\nPending orders: {hb.get('pending','unknown')}\nEquity: {hb.get('equity','unknown')}"
                elif command == '/dailyreport':
                    with lock: hb=dict(state['heartbeat'])
                    reply=f"Latest MT5 snapshot\nSymbol: {hb.get('symbol','unknown')}\nBalance: {hb.get('balance','unknown')}\nEquity: {hb.get('equity','unknown')}\nReported daily P/L: {hb.get('daily_pl','unknown')}\nPositions: {hb.get('positions','unknown')}\nPending: {hb.get('pending','unknown')}"
                elif command == '/pause':
                    with lock: state['paused']=True
                    reply='PAUSED. The EA should cancel its pending orders on the next status check. Existing positions still require MT5 protective management.'
                    log.warning('Trading paused from authorised Telegram chat')
                elif command == '/stop':
                    with lock: state['stopped']=True; state['paused']=False
                    reply='EMERGENCY STOP active: no new AI-approved entries. The EA should cancel pending orders on its next status check. Existing positions are not automatically liquidated.'
                    log.warning('Emergency entry stop activated from Telegram')
                elif command == '/resume':
                    with lock: state['stopped']=False; state['paused']=False
                    reply='Trading service re-enabled. Confirm MT5, broker, risk limits, and demo status before use.'
                    log.warning('Trading resumed from authorised Telegram chat')
                else:
                    reply='Unknown command. Send /help.'
                if reply: telegram_send_to_chat(chat, reply)
        except Exception as exc:
            log.warning('Telegram polling error: %s', type(exc).__name__)
            time.sleep(3)

def telegram_send_to_chat(chat_id: str, message: str) -> None:
    if not TELEGRAM_TOKEN: return
    try:
        payload=json_bytes({'chat_id':chat_id,'text':message[:3900]})
        req=urllib.request.Request(f'https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage',data=payload,headers={'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=8) as r: r.read()
    except Exception as exc: log.warning('Telegram reply failed: %s',type(exc).__name__)

class Handler(BaseHTTPRequestHandler):
    server_version = 'FvgGoldAI/1.0'
    def log_message(self, fmt, *args):
        # BaseHTTPRequestHandler logs method/path/status, never auth headers.
        log.info('http %s - %s', self.address_string(), fmt % args)
    def send(self, code: int, obj: dict):
        data = json_bytes(obj)
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            log.debug('Client disconnected before response completed')
    def authorized(self) -> bool:
        # Keep the EA's existing header, and also accept standard Bearer auth
        # for PowerShell/manual diagnostics. Never accept an empty token.
        supplied = (self.headers.get('X-Service-Token') or '').strip()
        if not supplied:
            auth = (self.headers.get('Authorization') or '').strip()
            if auth.lower().startswith('bearer '):
                supplied = auth[7:].strip()
        return bool(supplied and SERVICE_TOKEN) and secrets.compare_digest(
            supplied.encode('utf-8'), SERVICE_TOKEN.encode('utf-8')
        )
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/health':
            return self.send(200, {
                'ok': True, 'service': 'FvgGold AI', 'model': MODEL,
                'auth_required_for_protected_endpoints': True
            })
        if not self.authorized():
            return self.send(401, {'ok': False, 'error': 'unauthorized',
                                   'hint': 'Send X-Service-Token or Authorization: Bearer <token>'})
        if path == '/status':
            return self.send(200, status_payload())
        if path == '/analysis':
            with lock: a=dict(state['last_analysis'])
            return self.send(200,{'ok':True,'analysis':a})
        if path == '/report':
            with lock: hb=dict(state['heartbeat'])
            return self.send(200,{'ok':True,'heartbeat':hb,'status':status_payload()})
        if path == '/version':
            return self.send(200, {'ok': True, 'service': 'FvgGold AI', 'version': self.server_version})
        return self.send(404, {'ok': False, 'error': 'not_found', 'path': path})

    def do_POST(self):
        path = urlsplit(self.path).path
        if not self.authorized():
            return self.send(401, {'ok': False, 'error': 'unauthorized',
                                   'hint': 'Send X-Service-Token or Authorization: Bearer <token>'})
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length <= 0 or length > 65536: return self.send(413,{'ok':False,'error':'invalid_body_size'})
            body=json.loads(self.rfile.read(length).decode('utf-8'))
            if not isinstance(body,dict): return self.send(400,{'ok':False,'error':'JSON object required'})
        except Exception: return self.send(400,{'ok':False,'error':'invalid_json'})
        if path == '/heartbeat':
            with lock:
                previous=state['heartbeat']; oldpos=previous.get('positions')
                state['heartbeat']=body; state['last_heartbeat']=time.time()
            if oldpos is not None and body.get('positions') != oldpos:
                threading.Thread(target=telegram_send, args=(f"MT5 position count changed: {oldpos} -> {body.get('positions')}\nSymbol: {body.get('symbol')}\nEquity: {body.get('equity')}",), daemon=True).start()
            return self.send(200,{'ok':True})
        if path != '/decision': return self.send(404, {'ok': False, 'error': 'not_found', 'path': path})
        err=validate_candidate(body)
        if err:
            out={'ok':True,'decision':'WAIT','approved':False,'confidence':0.0,'reason':err,'risk_notes':'Local conservative gate rejected candidate'}
            with lock: state['last_decision']=out; state['last_analysis']=out
            return self.send(200,out)
        try:
            result=call_gemini(body)
            decision=result['decision']; confidence=result['confidence']; reason=result['reason']; notes=result['risk_notes']
            # Server-side independent gate: direction must match and confidence pass threshold.
            approved=(decision == str(body['direction']).upper() and confidence >= MIN_CONFIDENCE and active_state())
            out={'ok':True,'decision':decision,'approved':bool(approved),'confidence':confidence,
                 'reason':reason,'risk_notes':notes,'model':MODEL,'key_slot':result.get('key_slot')}
            with lock: state['last_decision']=out; state['last_analysis']=out
            log.info('AI review symbol=%s candidate=%s decision=%s approved=%s confidence=%.2f',body.get('symbol'),body.get('direction'),decision,approved,confidence)
            if not approved:
                threading.Thread(target=telegram_send, args=(f"FvgGold AI: {body.get('symbol')} {body.get('direction')} not approved. Decision={decision}, confidence={confidence:.2f}. {reason}",), daemon=True).start()
            else:
                threading.Thread(target=telegram_send, args=(f"FvgGold AI APPROVED: {body.get('symbol')} {decision}\nConfidence: {confidence:.2f}\nEntry: {body.get('entry')}\nSL: {body.get('stop_loss')}\nTP: {body.get('take_profit')}\nReason: {reason}",), daemon=True).start()
            return self.send(200,out)
        except Exception as exc:
            log.error('AI decision unavailable: %s',type(exc).__name__)
            with lock: state['last_error']=type(exc).__name__
            # No fallback approval: unavailable AI means WAIT.
            return self.send(503,{'ok':False,'decision':'WAIT','approved':False,'confidence':0.0,'reason':'AI service unavailable; fail-closed','error':type(exc).__name__})

def main():
    server=ThreadingHTTPServer((HOST,PORT),Handler)
    server.daemon_threads=True
    log.info('FvgGold AI service listening on %s:%s; model=%s; Gemini key slots=%s',HOST,PORT,MODEL,len(GEMINI_KEYS))
    if TELEGRAM_TOKEN and ALLOWED_CHAT_IDS:
        threading.Thread(target=telegram_loop,daemon=True,name='telegram-poller').start()
    try: server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt: pass
    finally: server.server_close()

if __name__ == '__main__': main()
