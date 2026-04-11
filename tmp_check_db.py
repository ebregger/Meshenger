import urllib.request, json
for p in [18081, 18082, 18083]:
    try:
        data = urllib.request.urlopen(f'http://127.0.0.1:{p}/messages').read()
        msgs = json.loads(data)['messages']
        print(f"Port {p}: {len(msgs)} messages")
        # Print the first 3 msgIds just to see what they have
        for m in msgs[:3]: print(f"  {m['msgId']} - {m['textContent']}")
    except Exception as e:
        print(f"Port {p}: {e}")
