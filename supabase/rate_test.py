import subprocess, os, concurrent.futures

token = os.environ['ACCESS_TOKEN']

def make_request(i):
    result = subprocess.run(
        ['curl', '-s', '-w', '%{http_code}', '-o', '/dev/null', '--max-time', '5',
         '-X', 'POST', 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat',
         '--header', 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6',
         '--header', f'Authorization: Bearer {token}',
         '--header', 'Content-Type: application/json',
         '--data', '{"sessionId":"rate-burst","message":"Request ' + str(i) + '"}'],
        capture_output=True, text=True, timeout=10)
    return i, result.stdout.strip()

with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:
    futures = [executor.submit(make_request, i) for i in range(1, 16)]
    results = []
    for f in concurrent.futures.as_completed(futures):
        try:
            results.append(f.result())
        except Exception as e:
            results.append((-1, str(e)))

results.sort(key=lambda x: x[0])
for i, status in results:
    print(f'Request {i}: HTTP {status}')

statuses = [s for _, s in results]
print(f'\nSummary: {statuses.count("429")} rate-limited, {statuses.count("200")} ok, {statuses.count("502")} upstream')
