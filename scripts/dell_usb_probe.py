#!/usr/bin/env python3
"""U4025QW diagnostic: HID queries only; no monitor-setting writes.

Transport/auth adapted from Joshua Perry's fwupd dell-monitor-rt branch.
SPDX-License-Identifier: LGPL-2.1-or-later
https://github.com/joshperry/fwupd/tree/dell-monitor-rt/plugins/dell-monitor-rt
"""
import argparse, functools, json, operator, sys, time
from pathlib import Path
import hid

SIZE=192
SEED=bytes.fromhex('f8 b7 fd 21 e0 32 22 b8 a9 e8 7c 11 04 94 e2 9d 9f 6a')
VCP={0x60:'main_input',0xE8:'secondary_input',0xE9:'layout',0xD6:'power_mode'}
def synkey():
    result=[]; i=0
    while i<len(SEED) and len(result)<8:
        t=SEED[i]; b=t&0x11
        if b in (1,16):
            result.append(t^SEED[i+1]); i+=2
        elif b==17:
            result.extend((t^SEED[i+1],SEED[i+2]^SEED[i+1])); i+=3
        else: i+=1
    return bytes(result[:8])

def checksum(data,initial):
    return functools.reduce(operator.xor,data,initial)

class Probe:
    def __init__(self):
        found=[d for d in hid.enumerate(0x0bda,0x1100) if d['usage_page']==0xffda]
        if len(found)!=1: raise RuntimeError(f'Expected one primary Dell HID, found {len(found)}')
        self.dev=hid.device(); self.dev.open_path(found[0]['path']); self.active=False
    def send(self,frame):
        # Closed allowlist: transport setup/auth, version query, and DDC GET only.
        f=bytes(frame)
        if len(f)!=SIZE: raise ValueError('Invalid report size')
        op=f[1]
        allowed=False
        if op==2:
            allowed=f[:6]==bytes.fromhex('40 02 01 00 da 0b') and not any(f[6:])
        elif op==6:
            allowed=f[0]==0x40 and f[2] in (0,1) and not any(f[3:])
        elif op==9:
            allowed=f[:7]==bytes.fromhex('c0 09 00 00 00 00 20') and not any(f[7:])
        elif op==0xe1:
            allowed=(f[:4]==bytes.fromhex('40 e1 01 01') and not any(f[4:])) or (f[:4]==bytes.fromhex('40 e1 03 00') and not any(f[4:64]) and not any(f[72:]))
        elif op in (0xc6,0xd6):
            header=bytearray(SIZE); header[0]=0x40; header[1]=op; header[6]=f[6]; header[8]=0x6e
            if op==0xc6:
                payload=f[64:64+f[6]]
                standard=len(payload)==5 and payload[:3]==bytes.fromhex('51 82 01') and payload[3] in VCP and checksum(payload,0x6e)==0
                vendor=payload==bytes.fromhex('51 84 c0 99 ad 18 57')
                header[64:64+len(payload)]=payload
                allowed=(standard or vendor) and f==header
            else: allowed=f[6]==64 and f==header
        if not allowed: raise ValueError(f'Frame blocked by query allowlist: opcode {op:02x}')
        n=self.dev.write(bytes([0])+f)
        if n not in (SIZE,SIZE+1): raise RuntimeError(f'Short HID write: {n}')
    def command(self,direction,op,sub=0,arg=0,payload=b''):
        f=bytearray(SIZE); f[:4]=bytes((direction,op,sub,arg)); f[4:4+len(payload)]=payload; self.send(f)
    def receive(self):
        raw=bytes(self.dev.get_input_report(0,SIZE+1))
        if len(raw)==SIZE+1 and raw[0]==0: raw=raw[1:]
        if len(raw)!=SIZE: raise RuntimeError(f'Unexpected input report length {len(raw)}')
        return raw
    def start(self):
        self.command(0x40,2,1,payload=bytes.fromhex('da 0b'))
        self.active=True
        self.command(0x40,6,1)
    def handshake(self):
        self.command(0x40,0xe1,1,1)
        challenge=self.receive()[:16]
        if not any(challenge): raise RuntimeError('Empty auth challenge')
        even=((challenge[0]<<8)|challenge[15]).bit_count()%2==0
        tmp=bytearray(challenge[8:] if even else challenge[:8])
        idx=challenge[6 if even else 14]&7
        tmp[idx]^=challenge[idx if even else idx+8]
        answer=bytes(a^b for a,b in zip(tmp,synkey()))
        f=bytearray(SIZE); f[:4]=bytes.fromhex('40 e1 03 00'); f[64:72]=answer; self.send(f)
    def query(self,payload):
        self.handshake()
        f=bytearray(SIZE); f[0]=0x40; f[1]=0xc6; f[6]=len(payload); f[8]=0x6e; f[64:64+len(payload)]=payload
        self.send(f); time.sleep(.06)
        f=bytearray(SIZE); f[0]=0x40; f[1]=0xd6; f[6]=64; f[8]=0x6e
        self.send(f); return self.receive()
    def get_vcp(self,code):
        p=bytes((0x51,0x82,1,code)); p+=bytes((checksum(p,0x6e),))
        r=self.query(p)
        if r[:3]!=bytes.fromhex('6e 88 02') or r[4]!=code: raise RuntimeError(f'Invalid VCP reply for {code:02x}: {r[:16].hex()}')
        if checksum(r[:11],0x50)!=0: raise RuntimeError('DDC reply checksum mismatch')
        if r[3]!=0: raise RuntimeError(f'VCP {code:02x} unsupported, result={r[3]}')
        return {'current':int.from_bytes(r[8:10],'big'),'maximum':int.from_bytes(r[6:8],'big'),'type':r[5],'reply':r[:11].hex()}
    def close(self):
        try:
            if self.active:
                try: self.handshake()
                finally: self.command(0x40,6,0)
        finally: self.dev.close()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--state',action='store_true',help='Also query firmware tag and four VCP registers')
    ap.add_argument('--output',type=Path,help='Write the diagnostic result to a JSON file')
    args=ap.parse_args()
    p=Probe(); result={'transport':'USB HID 0bda:1100','setting_writes':0}
    try:
        p.start(); p.command(0xc0,9,payload=bytes.fromhex('00 00 20'))
        r=p.receive()
        if not any(r): raise RuntimeError('Empty hub version reply')
        result['hub_version_candidate']=f'{r[12]:X}.{r[11]:02X}'
        result['hub_reply']=r[:24].hex()
        print(json.dumps(result),flush=True)
        if args.state:
            r=p.query(bytes.fromhex('51 84 c0 99 ad 18 57'))
            n=(r[1]&0x7f)+3
            if r[0]!=0x51 or r[2] not in (0xc0,0xc1) or r[3]!=0x99 or not 5<=n<=64: raise RuntimeError('Invalid firmware tag reply: '+r[:32].hex())
            if checksum(r[:n],0x50)!=0: raise RuntimeError('Vendor reply checksum mismatch')
            result['firmware_tag_reply']=r[:n].hex()
            try: result['firmware_tag']=r[4:n-1].split(b'\0')[0].decode('ascii',errors='strict')
            except UnicodeDecodeError: result['firmware_tag_error']='Non-ASCII vendor reply; not interpreted as a firmware version'
            for code,name in VCP.items():
                try: result[name]=p.get_vcp(code)
                except Exception as e: result[name]={'error':str(e)}
                print(json.dumps({name:result[name]}),flush=True)
            print(json.dumps(result,indent=2),flush=True)
    finally: p.close()
    if args.output:
        args.output.write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__': main()
