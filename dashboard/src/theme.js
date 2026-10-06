// Applies a saved light/dark choice before first paint (no flash). Classic script, loaded in <head>;
// a separate file rather than inline so the Content-Security-Policy can forbid inline scripts.
try { const t = localStorage.getItem('nvcm-dash-theme'); if (t) document.documentElement.dataset.theme = t; } catch { /* storage unavailable */ }
