// ==UserScript==
// @name         ChatGPT Timestamp + Linebreak
// @namespace    http://tampermonkey.net/
// @version      6.3
// @description  Prepends timestamp with a linebreak before sending messages
// @match        https://chatgpt.com/*
// @match        https://chat.openai.com/*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';

    const getCompactTimestamp = () => {
        const now = new Date();
        const hh = now.getHours().toString().padStart(2,'0');
        const mm = now.getMinutes().toString().padStart(2,'0');
        const dd = now.getDate().toString().padStart(2,'0');
        const MM = (now.getMonth()+1).toString().padStart(2,'0');
        const yy = now.getFullYear().toString().slice(-2);
        return `${hh}:${mm} (${dd}/${MM}/${yy})`;
    };

    const getEditor = () => document.querySelector('#prompt-textarea');

    const prependTimestamp = () => {
        const editor = getEditor();
        if (!editor) return;

        let text = editor.innerText.trim();
        if (!text) return;
        if (/^\d{2}:\d{2}\s*\(/.test(text)) return;

        const stamp = getCompactTimestamp();
        const newText = `${stamp}\n\n${text}`;

        // Using execCommand to ensure React state is updated
        editor.focus();
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, newText);
    };

    // Trigger before sending
    document.addEventListener('keydown', (e) => {
        if ((e.key==='Enter' && !e.shiftKey) || ((e.metaKey||e.ctrlKey)&&e.key==='Enter')) {
            prependTimestamp();
        }
    }, { capture:true });

    document.addEventListener('click', (e)=>{
        const sendBtn = document.querySelector(
            '[data-testid="send-button"], button[aria-label*="Send prompt"], button[data-testid*="send-"]'
        );
        if(sendBtn && (sendBtn===e.target || sendBtn.contains(e.target))){
            prependTimestamp();
        }
    }, { capture:true });

})();
