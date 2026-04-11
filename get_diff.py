import urllib.request, json
d1 = json.loads(urllib.request.urlopen('http://127.0.0.1:18081/messages').read())['messages']
d2 = json.loads(urllib.request.urlopen('http://127.0.0.1:18082/messages').read())['messages']

s1 = {m['msgId']: m for m in d1}
s2 = {m['msgId']: m for m in d2}

missing_in_2 = set(s1.keys()) - set(s2.keys())
print(f"Missing in device 2: {len(missing_in_2)}")
if len(missing_in_2) > 0:
    sample_id = list(missing_in_2)[0]
    print(f"Sample missing message: {s1[sample_id]}")
