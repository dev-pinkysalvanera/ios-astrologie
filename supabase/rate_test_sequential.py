"""Sequential rate limit test: sends requests one at a time to the same isolate."""
import subprocess, os, time

token = os.environ['ACCESS_TOKEN']

for i in range(1, 25):
    result = subprocess.run(
        ['curl', '-s', '-w', '\n%{http_code}', '--max-time', '5',
         '-X', 'POST', 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat',
         '--header', 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6',
         '--header', f'Authorization: Bearer {token}',
         '--header', 'Content-Type: application/json',
         '--data', '{"sessionId":"seq-rate-test","message":"R' + str(i) + '"}'],
        capture_output=True, text=True, timeout=10)
    lines = result.stdout.strip().split('\n')
    status = lines[-1] if lines else '?'
    body_preview = lines[0][:80] if lines else ''
    print(f'Request {i:2d}: HTTP {status} | {body_preview}')
    if status == '429':
        print(f'  -> Rate limited! Body: {result.stdout}')
        break
    # Small delay to avoid overwhelming but stay within the window
    time.sleep(0.1)
