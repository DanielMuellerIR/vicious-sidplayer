const webDialogFocus = new WeakMap();

function showWebDialog(dialog, { initialFocus, fallbackID } = {}) {
  if (dialog.open) return;
  const previous = webDialogFocus.get(dialog);
  if (previous) {
    dialog.removeEventListener('close', previous.restoreFocus);
    dialog.removeEventListener('keydown', previous.cycleFocus);
  }
  const opener = document.activeElement;
  const cycleFocus = event => {
    if (event.key !== 'Tab' || event.ctrlKey || event.altKey || event.metaKey) return;
    const controls = [...dialog.querySelectorAll('button, [href], input, select, textarea, [tabindex]')]
      .filter(element => element.tabIndex >= 0 && !element.disabled && element.getClientRects().length);
    if (!controls.length) { event.preventDefault(); return; }
    const index = controls.indexOf(document.activeElement);
    if (index < 0 || event.shiftKey && index === 0 || !event.shiftKey && index === controls.length - 1) {
      event.preventDefault(); controls[event.shiftKey ? controls.length - 1 : 0].focus();
    }
  };
  const restoreFocus = () => {
    // Ein verspätetes close-Ereignis darf einen erneut geöffneten Dialog nicht verlassen.
    if (dialog.open) return;
    dialog.removeEventListener('close', restoreFocus);
    dialog.removeEventListener('keydown', cycleFocus);
    webDialogFocus.delete(dialog);
    const visible = element => element?.isConnected && !element.disabled && element.getClientRects().length;
    const fallback = fallbackID && document.getElementById(fallbackID);
    const target = visible(opener) ? opener : visible(fallback) ? fallback : null;
    target?.focus();
  };
  webDialogFocus.set(dialog, { restoreFocus, cycleFocus });
  dialog.addEventListener('close', restoreFocus);
  dialog.addEventListener('keydown', cycleFocus);
  dialog.showModal();
  const target = initialFocus || dialog.querySelector('h2, h3');
  if (target) {
    if (!initialFocus) target.tabIndex = -1;
    target.focus();
  }
}

function readableWebTime(seconds) {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const minutes = Math.floor(total / 60), remainder = total % 60;
  return `${minutes} minute${minutes === 1 ? '' : 's'}, ${remainder} second${remainder === 1 ? '' : 's'}`;
}

function refreshWebMediaAccessibility() {
  // Ganze Sekunden vermeiden zusätzliche Accessibility-Updates im Zeichentakt.
  const values = [[positionScrubber, `${readableWebTime(Number(positionScrubber.value))} of ${readableWebTime(currentWebDuration())}`],
    [volumeSlider, `${Math.round(Number(volumeSlider.value) * 100)} percent`]];
  for (const [element, value] of values) {
    if (element.getAttribute('aria-valuetext') !== value) element.setAttribute('aria-valuetext', value);
  }
}
