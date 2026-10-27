/* PWA installation UI only. Sensitive records are never cached or used here. */
(() => {
  'use strict';
  let deferredInstall = null;
  const root = document.getElementById('pwaInstallRoot');
  if (!root) return;
  const installed = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const mobile = () => /android|iphone|ipad|ipod/i.test(navigator.userAgent) || window.matchMedia('(max-width: 650px)').matches;
  const dismissed = () => { try {return sessionStorage.getItem('pmp-install-dismissed') === 'yes';} catch {return false;} };
  const hide = () => {root.replaceChildren();};
  const dismiss = () => {try {sessionStorage.setItem('pmp-install-dismissed','yes');} catch {} hide();};
  function instructions() {
    const apple = /iphone|ipad|ipod/i.test(navigator.userAgent);
    const modal = document.createElement('div');
    modal.className = 'pwa-scrim'; modal.setAttribute('role','dialog'); modal.setAttribute('aria-modal','true');
    modal.setAttribute('aria-label','วิธีติดตั้งแอป');
    modal.innerHTML = `<div class="pwa-modal"><button class="pwa-modal__close" type="button" aria-label="ปิด">×</button><img class="pwa-modal__icon" src="assets/icon-192.png" alt="ไอคอน Pregnant Manager Pro"><h2>ติดตั้ง Pregnant Manager Pro</h2>${apple?
      '<p><strong>บน iPhone / iPad</strong></p><ol><li>เปิดเว็บไซต์นี้ใน Safari</li><li>แตะไอคอนแชร์ (Share)</li><li>เลือก <strong>Add to Home Screen</strong></li><li>เปิด <strong>Open as Web App</strong> ถ้ามี แล้วแตะ Add</li></ol>':
      '<p><strong>บน Android / Chrome</strong></p><ol><li>เปิดเว็บไซต์นี้ผ่าน HTTPS ใน Chrome</li><li>แตะเมนู ⋮ ของเบราว์เซอร์</li><li>เลือก <strong>Install app</strong> หรือ <strong>Add to Home screen</strong></li></ol>'}
      <p style="font-size:11px;color:#777">ต้องอัปโหลดไฟล์ขึ้น GitHub Pages ก่อนจึงจะติดตั้งจากลิงก์ได้ การบันทึกและซิงก์ข้อมูลสุขภาพต้องเชื่อมต่ออินเทอร์เน็ต</p><button type="button" class="pwa-action pwa-modal__done">เข้าใจแล้ว</button></div>`;
    document.body.appendChild(modal);
    const close = () => modal.remove();
    modal.querySelector('.pwa-modal__close').addEventListener('click',close);
    modal.querySelector('.pwa-modal__done').addEventListener('click',close);
    modal.addEventListener('click',e => {if(e.target === modal) close();});
  }
  async function install() {
    if (deferredInstall) {
      const event = deferredInstall; deferredInstall = null;
      try { await event.prompt(); const choice = await event.userChoice;
        if (choice?.outcome === 'accepted') { hide(); return; }
      } catch { /* fall back to instructions */ }
    }
    instructions();
  }
  function banner() {
    if (installed() || dismissed() || !mobile() || root.childElementCount) return;
    root.innerHTML = '<div class="pwa-pill"><img class="pwa-pill__icon" src="assets/icon-192.png" alt=""><span class="pwa-pill__desc"><strong>พกสมุดครอบครัวติดมือถือ</strong><small>ติดตั้งเป็นแอป ฟรี ไม่ต้องผ่าน App Store</small></span><button class="pwa-action" type="button" id="pwaInstallNow">ติดตั้ง</button><button class="pwa-dismiss" type="button" id="pwaInstallDismiss" aria-label="ปิดคำแนะนำ">×</button></div>';
    root.querySelector('#pwaInstallNow').addEventListener('click', install);
    root.querySelector('#pwaInstallDismiss').addEventListener('click', dismiss);
  }
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault(); deferredInstall = event; banner();
  });
  window.addEventListener('appinstalled', () => {deferredInstall = null; hide();});
  window.matchMedia('(display-mode: standalone)').addEventListener?.('change',()=>{if(installed())hide();});
  window.addEventListener('load', () => {
    if (window.isSecureContext && 'serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js', {updateViaCache:'none'}).catch(err=>console.warn('App install registration:',err));
    banner();
  });
})();
