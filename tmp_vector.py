import urllib.request, json
from collections import defaultdict

for p in [18081, 18082, 18083]:
    try:
        data = urllib.request.urlopen(f'http://127.0.0.1:{p}/messages').read()
        msgs = json.loads(data)['messages']
        vec = defaultdict(int)
        # Vector is calculated using simple count of messages per originNodeId for analysis
        for m in msgs:
            vec[m['originNodeId']] += 1
        print(f"Port {p} Vector: {dict(vec)}")
    except Exception as e:
        print(f"Port {p} error: {e}")
