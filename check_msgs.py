import urllib.request, json

PORTS = [18081, 18082, 18083]
for p in PORTS:
    try:
        url = f'http://127.0.0.1:{p}/messages'
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
            msgs = data.get('messages', [])
            stress = [m for m in msgs if 'steady test message' in m.get('textContent', '')]
            print(f'Port {p}: {len(msgs)} total msgs, {len(stress)} stress-test msgs')
    except Exception as e:
        print(f'Port {p}: ERROR {e}')
