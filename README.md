1. Start IPhone mirroring
2. Start VoiceOver (needed to enable remote AX from iPhone)
3. Run this:
```
sudo dtrace -p $PID -s ./sniff.d > /tmp/axstream.txt 2>/dev/null
```
4. Hook it up with an AI agent and control your iPhone?
