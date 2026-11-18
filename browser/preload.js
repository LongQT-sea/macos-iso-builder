'use strict';
// Bridge for the toolbar UI only. Web pages never get this preload.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('feather', {
  send: (cmd, arg) => ipcRenderer.send('ui', cmd, arg),
  on: (channel, fn) => {
    if (!['tabs', 'focus-address', 'fullscreen', 'find', 'find-result'].includes(channel)) return;
    ipcRenderer.on(channel, (_e, data) => fn(data));
  },
});
