// Launched by admin_api.py against its private loopback instance and test identities only.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {chromium} = require('playwright');

async function main() {
  const dir=process.argv[2];
  const config=JSON.parse(fs.readFileSync(path.join(dir,'browser.json')));
  assert.equal(new URL(config.origin).hostname,'127.0.0.1');
  const browser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args:['--no-sandbox','--disable-dev-shm-usage']});
  const page=await browser.newPage({locale:'en-US',viewport:{width:1440,height:1000}});
  page.setDefaultTimeout(12000);
  const button=s=>page.getByRole('button',{name:s,exact:true}).last();
  async function fill(label,value) {
    const locator=page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`).first();
    await locator.click();await page.waitForTimeout(150);
    await page.keyboard.press('Control+a');await page.keyboard.insertText(value);
    await page.waitForTimeout(100);await page.keyboard.press('Tab');
  }
  let token;
  async function snapshot(){
    const response=await page.request.get(config.origin+'/api/v1/admin/workspace-agents',{headers:{Authorization:'Bearer '+token}});
    assert.equal(response.status(),200);
    return response.json();
  }
  async function until(fn,seconds=70){
    const end=Date.now()+seconds*1000;
    do {if(await fn())return;await page.waitForTimeout(350);}while(Date.now()<end);
    throw new Error('Timed out waiting for fixture state');
  }
  async function cluster(phase,node){
    await until(async()=>{const c=(await snapshot()).clusters.find(c=>c.cluster==='engineering');
      return c?.phase===phase && c.node===node;});
  }
  async function clickAction(label,action){
    const response=page.waitForResponse(r=>r.url().endsWith('/api/v1/admin/workspace-agents') && r.request().method()==='POST' && r.request().postDataJSON()?.action===action);
    await button(label).click();assert.equal((await response).status(),200,action);
  }
  let stage='bootstrap';
  try{
    await page.goto(config.origin,{waitUntil:'domcontentloaded'});
    await page.locator('flt-semantics-placeholder').evaluate(e=>e.click());
    const owner=page.locator('input[aria-label*="Owner email"]');
    await until(async()=>await owner.count()>0 || await page.locator('input[aria-label*="Server URL"]').count()>0);
    if(await owner.count()===0){await fill('Server URL',config.origin);await button('Connect securely').click();}
    await fill('Owner email',config.username);
    const pass=crypto.randomBytes(24).toString('hex')+'Aa!';
    await fill('Master password',pass);await fill('Confirm master password',pass);await fill('One-time bootstrap token',config.bootstrap);
    const registration=page.waitForResponse(r=>r.url().endsWith('/api/v1/auth/register') && r.request().method()==='POST',{timeout:45000});
    await button('Create owner account').click();
    const receipt=await registration;assert.ok([200,201].includes(receipt.status()));
    token=(await receipt.json()).access_token;assert.ok(token);
    fs.writeFileSync(path.join(dir,'admin.token'),token,{mode:0o600});
    stage='native admin route';
    const adminNav=page.getByRole('button',{name:/^Admin(?: Admin)?$/}).first();
    await until(async()=>{
      if(await button('I understand').isVisible()) await button('I understand').click();
      return await adminNav.isVisible();
    });
    await adminNav.click();
    await until(()=>new URL(page.url()).pathname==='/admin');
    const agentsSection=page.getByRole('button',{name:/^Workspace agents/}).first();
    await agentsSection.click();
    await button('Register node').waitFor({state:'visible'});
    for(const node of ['alpha','beta']){
      stage='register '+node; console.log(stage);
      await button('Register node').click();
      const chooser=page.waitForEvent('filechooser');await button('Choose public JSON').click();
      await (await chooser).setFiles(path.join(dir,node+'.private.tar.public.json'));
      await clickAction('Register node','register_node');
      await until(async()=>(await snapshot()).nodes.some(n=>n.name===node));
    }
    stage='create second workspace';
    await button('Create workspace').click();
    await fill('Name','extra');await fill('Port',String(config.extra_port));
    await fill('Authorized SSH public keys',fs.readFileSync(path.join(dir,'user-key.pub'),'utf8').trim());
    await clickAction('Create','create_workspace');
    stage='publish a host';
    await button('Publish SSH service').click();await fill('Name','office');await fill('Port',String(config.host_port));
    await clickAction('Publish SSH service','publish_host');
    await cluster('Running','alpha');
    const ssh=(command,first=false)=>execFileSync('ssh',['-q','-oBatchMode=yes','-oIdentitiesOnly=yes','-oConnectTimeout=6',
      '-oUserKnownHostsFile='+path.join(dir,'known'),'-oStrictHostKeyChecking='+(first?'accept-new':'yes'),'-i',path.join(dir,'user-key'),
      '-p',String(config.port),'sandbox@127.0.0.1',command],{timeout:12000}).toString().trim();
    ssh('printf native-admin > ~/marker',true);
    stage='inspect and migrate';
    const tile=page.getByRole('button',{name:/engineering/}).first();
    await tile.click();
    await button('Migrate').click();await clickAction('Migrate','migrate');
    await cluster('Restore','alpha');
    stage='abort migration';
    await button('Cancel migration').click();await clickAction('Cancel migration','abort');
    fs.writeFileSync(path.join(dir,'start-beta'),'');
    await cluster('Running','alpha');
    assert.equal(ssh('cat ~/marker'),'native-admin');
    stage='cut over to second node';
    await button('Migrate').click();await clickAction('Migrate','migrate');await cluster('Running','beta');
    assert.equal(ssh('cat ~/marker'),'native-admin');
    assert.equal((await snapshot()).clusters.find(c=>c.cluster==='engineering').port,config.port);
    console.log('Chromium Admin: public enrollment file, workspace and host creation, migration, cancellation and SSH after cutover passed.');
  }catch(e){
    // Only UI labels, never account credentials, registration bodies or input values.
    console.error('Failed browser stage: '+stage);
    const labels=await page.locator('flt-semantics[role=button]').evaluateAll(es=>es.map(e=>(e.getAttribute('aria-label')||e.innerText).slice(0,90)).slice(-40)).catch(()=>[]);
    console.error('Visible button labels:',labels.join(' / '));
    throw e;
  }finally{await browser.close();}
}
main().catch(e=>{console.error(e.name+': '+e.message.split('\n').slice(0,3).join('\n'));process.exitCode=1;});
