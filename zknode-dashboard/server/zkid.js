import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import os from 'os';

const ZKID_DIR = process.env.ZKID_DIR || '/tmp/zkid';
try { fs.mkdirSync(ZKID_DIR, { recursive: true, mode: 0o700 }); } catch(_){}

function genMnemonic() {
  // Try zymkey HSM first (BIP32 master seed), fallback to random
  try {
    const out = require('child_process').execSync('python3 -c "import zymkey; s=zymkey.client.gen_wallet_master_seed(\'secp256k1\', \'\', \'zkid-disposable\'); print(s)"', { timeout: 5000, encoding: 'utf8' }).trim();
    if(out && /^\d+$/.test(out)) return 'zymkey-slot-' + out;
  } catch(_){}
  const bytes = crypto.randomBytes(32);
  return bytes.toString('hex').slice(0, 48);
}

function deriveAddress(seedHex){
  // Try keccak256 via hashlib.sha3_256 for EVM (like setup-zymbit.sh), fallback to sha256
  if(seedHex.startsWith('zymkey-slot-')){
    try {
      const slot = seedHex.split('-').pop();
      const out = require('child_process').execSync(`python3 -c "import zymkey,hashlib; pub=zymkey.client.get_public_key(int(${slot})); h=hashlib.sha3_256(pub).digest().hex(); print('0x'+h[-40:])"`, { timeout: 5000, encoding: 'utf8' }).trim();
      if(out.startsWith('0x')) return out;
    } catch(_){}
  }
  const h = crypto.createHash('sha256').update(seedHex).digest('hex');
  return '0x' + h.slice(0, 40);
}
function genSlip39(slot){
  try {
    const m = parseInt(slot.split('-').pop(),10);
    if(isNaN(m)) return null;
    const out = require('child_process').execSync(`python3 -c "import zymkey; m=zymkey.client.create_slip39_mnemonic(3,5,int(${m})); print('\\\\n'.join(m))"`, { timeout: 8000, encoding: 'utf8' }).trim();
    return out ? out.split('\n') : null;
  } catch(_){ return null; }
}

function toDataUrl(text, size=180){
  // minimal QR placeholder - real QR via qrcode lib if available, else data url with text
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><rect width="100%" height="100%" fill="white"/><text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" font-size="10" fill="black">${text.slice(0,12)}...</text></svg>`;
  return 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64');
}

export default function(app){
  app.post('/api/zkid/generate', (req, res) => {
    try {
      const seed = genMnemonic();
      const address = deriveAddress(seed);
      const zkId = crypto.createHash('sha256').update(seed + Date.now()).digest('hex').slice(0, 32);
      const qrDataUrl = toDataUrl(address);
      const slip39 = seed.startsWith('zymkey-slot-') ? genSlip39(seed) : null;
      const rec = { zkId, address, seed, qrDataUrl, slip39, createdAt: new Date().toISOString(), expiresAt: new Date(Date.now()+30*24*3600*1000).toISOString() };
      const file = path.join(ZKID_DIR, address + '.json');
      fs.writeFileSync(file, JSON.stringify(rec, null, 2), { mode: 0o600 });
      res.json({ zkId, address, qrDataUrl, seed: seed.slice(0,16)+'...', slip39: slip39 ? slip39.map((s,i)=>`Share ${i+1}: ${s.slice(0,16)}...`) : null, createdAt: rec.createdAt });
    } catch(e){ res.status(500).json({ error: e.message }); }
  });
  app.get('/api/zkid', (req, res) => {
    try {
      const files = fs.readdirSync(ZKID_DIR).filter(f=>f.endsWith('.json'));
      const list = files.map(f=>{ try{ const j=JSON.parse(fs.readFileSync(path.join(ZKID_DIR,f),'utf8')); return { address:j.address, zkId:j.zkId, createdAt:j.createdAt }; }catch(_){ return null; }}).filter(Boolean);
      res.json(list);
    } catch(e){ res.json([]); }
  });
  app.get('/api/zkid/:address', (req, res) => {
    try {
      const file = path.join(ZKID_DIR, req.params.address + '.json');
      if(!fs.existsSync(file)) return res.status(404).json({ error: 'not found' });
      const j = JSON.parse(fs.readFileSync(file,'utf8'));
      res.json({ address:j.address, zkId:j.zkId, qrDataUrl:j.qrDataUrl, createdAt:j.createdAt });
    } catch(e){ res.status(500).json({ error: e.message }); }
  });
  app.get('/api/zkid/:address/slip39', (req, res) => {
    try {
      const file = path.join(ZKID_DIR, req.params.address + '.json');
      if(!fs.existsSync(file)) return res.status(404).json({ error: 'not found' });
      const j = JSON.parse(fs.readFileSync(file,'utf8'));
      if(!j.slip39) return res.status(404).json({ error: 'no SLIP39 for this zkID (not zymkey)' });
      res.json({ address:j.address, slip39:j.slip39 });
    } catch(e){ res.status(500).json({ error: e.message }); }
  });
};
