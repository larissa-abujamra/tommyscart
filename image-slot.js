// <image-slot src placeholder shape> — fills its parent with an image, or a
// placeholder label when there is no src (or the src fails to load).
(() => {
  if (customElements.get('image-slot')) return;
  class ImageSlot extends HTMLElement {
    static get observedAttributes() { return ['src', 'placeholder', 'shape']; }
    connectedCallback() { this.render(); }
    attributeChangedCallback() { if (this.isConnected) this.render(); }
    render() {
      const src = this.getAttribute('src');
      const ph = this.getAttribute('placeholder') || '';
      Object.assign(this.style, { position: 'absolute', inset: '0', display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', borderRadius: this.getAttribute('shape') === 'circle' ? '50%' : '' });
      this.textContent = '';
      const label = () => {
        this.textContent = '';
        const s = document.createElement('span');
        s.textContent = ph;
        Object.assign(s.style, { fontFamily: "'DM Mono', monospace", fontSize: '12px', opacity: '.6', padding: '8px', textAlign: 'center' });
        this.appendChild(s);
      };
      if (!src) return label();
      const img = document.createElement('img');
      img.src = src; img.alt = ph; img.draggable = false;
      Object.assign(img.style, { width: '100%', height: '100%', objectFit: 'cover', display: 'block' });
      img.onerror = label;
      this.appendChild(img);
    }
  }
  customElements.define('image-slot', ImageSlot);

  // Hide images whose files are missing instead of showing broken-image icons,
  // and show them again once a later src loads. Only touch rendered images:
  // writing to a template <img>'s style would make the browser drop its
  // {{ }} declarations before the runtime reads them.
  const rendered = (t) => t && t.tagName === 'IMG' && t.closest('#dc-root');
  document.addEventListener('error', (e) => {
    if (rendered(e.target)) e.target.style.visibility = 'hidden';
  }, true);
  document.addEventListener('load', (e) => {
    if (rendered(e.target)) e.target.style.visibility = '';
  }, true);
})();
