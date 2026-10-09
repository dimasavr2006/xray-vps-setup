// HTTP acceptance against a disposable local Caddy Auth fixture, never a user's authenticator.
'use strict';
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');
const assert = require('assert/strict');
const fixture = JSON.parse(fs.readFileSync(0, 'utf8'));
assert.equal(fixture.host, 'fl.wf.md');
assert.equal(fixture.port, 39445);
assert.equal(fixture.address,'172.29.244.1');
const statePath = '/tmp/pdm-ci-mfa-state.json';
function session() {
  const cookies = new Map();
  async function request(path, data, follow = true) {
    assert(path.startsWith('/'));
    const body = data ? new URLSearchParams(data).toString() : '';
    const result = await new Promise((resolve, reject) => {
      const req = https.request({hostname:fixture.address, port:fixture.port, servername:fixture.host,
        rejectUnauthorized:false, method:data ? 'POST':'GET', path,
        headers:{Host:`${fixture.host}:${fixture.port}`,Cookie:[...cookies].map(([k,v])=>`${k}=${v}`).join('; '),
          ...(data ? {'Content-Type':'application/x-www-form-urlencoded','Content-Length':Buffer.byteLength(body)} : {})}},
        res => {let text='';res.on('data',c=>text+=c);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:text,path}));});
      req.setTimeout(10000,()=>req.destroy(new Error('HTTP test timeout')));req.on('error',reject);req.end(body);
    });
    for (const cookie of result.headers['set-cookie'] || []) {const pair=cookie.split(';')[0], i=pair.indexOf('=');cookies.set(pair.slice(0,i),pair.slice(i+1));}
    if (follow && [302,303,307,308].includes(result.status)) {
      const url=new URL(result.headers.location,`https://${fixture.host}:${fixture.port}`);
      assert.equal(url.hostname,fixture.host);assert.equal(Number(url.port),fixture.port);
      return request(url.pathname+url.search,undefined,follow);
    }
    return result;
  }
  return {request,cookies};
}
function fields(html) {
  const result={};
  for(const tag of html.match(/<input\b[^>]*>/g)||[]) {
    const name=tag.match(/name="([^"]+)"/),value=tag.match(/value="([^"]*)"/);
    if(name) result[name[1]]=value ? value[1].replace(/&amp;/g,'&').replace(/&#34;|&quot;/g,'"') : '';
  }
  return result;
}
function code(secret,offset=0) {
  const counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)+offset));
  const mac=crypto.createHmac('sha1',Buffer.from(secret,'utf8')).update(counter).digest();
  const index=mac.at(-1)&15;
  return String((mac.readUInt32BE(index)&0x7fffffff)%1000000).padStart(6,'0');
}
async function password(s) {
  let r=await s.request('/r');
  r=await s.request(r.path,{username:fixture.username,realm:'local'});
  console.log('Identity response:',r.status,'fields:',Object.keys(fields(r.body)).join(','),'title:',r.body.match(/<title>(.*?)<\/title>/)?.[1]);
  assert('secret' in fields(r.body),'password challenge missing');
  r=await s.request(r.path,{...fields(r.body),secret:fixture.password});
  return r;
}
(async()=>{
  const s=session();
  const unauth=await s.request('/api/auth/status',undefined,false);
  assert([302,303,401,403].includes(unauth.status));
  let r=await password(s), f=fields(r.body);
  if(!('passcode' in f) && !f.secret) {
    const link=r.body.match(/href="([^"]*mfa-app-register[^"]*)"/);
    assert(link,'MFA registration option missing');
    r=await s.request(link[1]);f=fields(r.body);
  }
  console.log('Password accepted; next challenge fields:',Object.keys(f).join(','));
  let secret;
  if(f.secret) {
    secret=f.secret;
    const denied=await s.request('/api/auth/status',undefined,false);
    assert([302,303,401,403].includes(denied.status),'password-only access must be denied');
    r=await s.request(r.path,{...f,period:'30',digits:'6',passcode:code(secret),comment:'Disposable CI authenticator'});
    fs.writeFileSync(statePath,JSON.stringify({secret}),{mode:0o600});
    console.log('TOTP enrollment confirmed through HTTP.');
  } else {
    secret=JSON.parse(fs.readFileSync(statePath,'utf8')).secret;
    r=await s.request(r.path,{...f,passcode:code(secret)});
  }
  const authorized=await s.request('/api/auth/status',undefined,false);
  assert.equal(authorized.status,200,'MFA must authorize protected API');
  const panelAuth=await s.request('/api/users?size=1',undefined,false);
  assert.equal(panelAuth.status,401,'Caddy MFA alone must not supply a Remnawave admin JWT');
  const fresh=session();
  r=await password(fresh);f=fields(r.body);
  assert('passcode' in f,'fresh login must require TOTP');
  assert(!('secret' in f),'existing enrollment must not be replaced');
  const denied=await fresh.request('/api/auth/status',undefined,false);
  assert([302,303,401,403].includes(denied.status));
  const current=code(secret),wrong=String((Number(current)+111111)%1000000).padStart(6,'0');
  await fresh.request(r.path,{...f,passcode:wrong},false);
  const stillDenied=await fresh.request('/api/auth/status',undefined,false);
  assert([302,303,401,403].includes(stillDenied.status),'invalid TOTP must not authorize');
  r=await fresh.request(r.path);f=fields(r.body);
  await fresh.request(r.path,{...f,passcode:code(secret)});
  assert.equal((await fresh.request('/api/auth/status',undefined,false)).status,200);
  console.log('Fresh login, wrong/correct code, protected API and separate Remnawave authentication passed.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
