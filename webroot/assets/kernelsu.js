/**
 * Imported from https://www.npmjs.com/package/kernelsu
 * Modified version by KOWX712 - https://www.npmjs.com/package/kernelsu-alt
 */

let callbackCounter = 0;
function getUniqueCallbackName(prefix) {
    return `${prefix}_callback_${Date.now()}_${callbackCounter++}`;
}

export function exec(command, options = {}) {
    return new Promise((resolve, reject) => {
        const callbackFuncName = getUniqueCallbackName("exec");
        window[callbackFuncName] = (errno, stdout, stderr) => {
            resolve({ errno, stdout, stderr });
            delete window[callbackFuncName];
        };
        try {
            if (typeof ksu !== 'undefined') {
                ksu.exec(command, JSON.stringify(options), callbackFuncName);
            } else {
                resolve({ errno: 1, stdout: "", stderr: "ksu is not defined" });
            }
        } catch (error) {
            reject(error);
            delete window[callbackFuncName];
        }
    });
}

export function toast(message) {
    if (typeof ksu !== 'undefined') {
        ksu.toast(message);
    } else {
        console.log(message);
    }
}

export function fullScreen(isFullScreen) {
    if (typeof ksu !== 'undefined') {
        ksu.fullScreen(isFullScreen);
    }
}