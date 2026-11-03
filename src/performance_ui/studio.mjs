// Presentation-only shell. No serial, protocol, device or provider access.
const tabs = Array.from(document.querySelectorAll('[data-view]'));
const panels = {performance:document.getElementById('performancePanel'),
  controls:document.getElementById('controlsPanel'),device:document.getElementById('devicePanel')};
function selectView(name, focus = false) {
  if (!panels[name]) return;
  for (const tab of tabs) {
    const active = tab.dataset.view === name;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    if (active && focus) tab.focus();
  }
  for (const [key,panel] of Object.entries(panels)) panel.hidden = key !== name;
}
tabs.forEach((tab,index) => {
  tab.addEventListener('click', () => selectView(tab.dataset.view));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) {event.preventDefault();selectView(tabs[next].dataset.view,true);}
  });
});
document.getElementById('presentationButton').addEventListener('click', event => {
  const active = document.documentElement.classList.toggle('presentation');
  event.currentTarget.setAttribute('aria-pressed', String(active));
  event.currentTarget.textContent = active ? '↙ 退出展演' : '↗ 展演模式';
});
selectView('performance');
