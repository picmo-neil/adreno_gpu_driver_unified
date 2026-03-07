import { exec, toast as ksuToast } from './assets/kernelsu.js';

// ============================================================
// MODULE AUTHOR LOCK
// ============================================================
// Reads module.prop and verifies that @pica_pica_picachu (or the
// short alias "picmo") appears anywhere in the author= line.
// The check is case-insensitive and works regardless of delimiter
// (commas, @-signs, spaces, hyphens, pipes — any separator).
//
// If the check fails the entire WebUI is replaced with a black
// lock screen. This protects against redistribution without credit.
// ============================================================

/**
 * Returns true if the module.prop author field contains a recognised
 * developer alias.  Accepted variants (case-insensitive, any position):
 *   pica_pica_picachu  — full Telegram username
 *   picmo              — short alias sometimes used in prop files
 */
async function checkModuleAuthor(modPath) {
    try {
        // Read just the author line — grep is faster than full cat on large props
        const res = await exec(
            `grep '^author=' "${modPath}/module.prop" 2>/dev/null || ` +
            `grep '^author=' /data/adb/modules/adreno_gpu_driver_unified/module.prop 2>/dev/null || ` +
            `grep '^author=' /data/adb/modules/adreno_gpu_driver/module.prop 2>/dev/null`
        );
        const raw = (res && res.stdout ? res.stdout : '').toLowerCase().trim();
        // Check for either known alias anywhere in the author value
        if (raw.includes('pica_pica_picachu') || raw.includes('picmo')) {
            return true;
        }
        return false;
    } catch (e) {
        // If we can't read module.prop at all, fail closed (show lock)
        return false;
    }
}

/**
 * Show the author lock screen and halt further JS execution by throwing.
 */
function showAuthorLockScreen() {
    const lock = document.getElementById('authorLockScreen');
    if (lock) lock.style.display = 'flex';
    // Hide the rest of the UI
    const main = document.querySelector('main');
    if (main) main.style.display = 'none';
    const nav = document.querySelector('nav, .bottom-nav, .nav-bar');
    if (nav) nav.style.display = 'none';
    const canvas = document.getElementById('particleCanvas');
    if (canvas) canvas.style.display = 'none';
}

// ============================================================
// ANDROID SDK VERSION — cached after first read
// ============================================================
let _cachedSdkVer = null;
async function getAndroidSdkVer() {
    if (_cachedSdkVer !== null) return _cachedSdkVer;
    try {
        const res = await exec('getprop ro.build.version.sdk 2>/dev/null');
        const v = parseInt((res && res.stdout ? res.stdout : '0').trim(), 10);
        _cachedSdkVer = isNaN(v) ? 0 : v;
    } catch (e) {
        _cachedSdkVer = 0;
    }
    return _cachedSdkVer;
}

// ============================================
// LIGHTWEIGHT PARTICLE ENGINE — Optimized for budget mobile WebView
// Adreno 610 (Snapdragon 665) friendly: low count, simple shapes only, no heavy gradients per-particle
// ============================================

class ParticleBackground {
    constructor(canvas) {
        this.canvas = canvas;
        this.ctx = canvas.getContext('2d', { alpha: true });
        this.particles = [];
        this.shootingStars = [];
        this.sparkles = [];
        // Performance mode defaults — conservative for budget devices
        this.performanceMode = true; // true = perf, false = quality
        this.particleCount = Math.min(55, Math.floor(window.innerWidth / 8));
        this.animationId = null;
        this.lastTime = 0;
        this.currentColor = null;
        this.frameCount = 0;
        // Reusable offscreen canvas for particle rendering (avoids repeated state changes)
        this._cachedRgb = null;

        this.resize();
        this.animate();

        let resizeTimeout;
        window.addEventListener('resize', () => {
            clearTimeout(resizeTimeout);
            resizeTimeout = setTimeout(() => this.resize(), 250);
        }, { passive: true });
    }

    _readThemeColor() {
        try {
            const rgb = getComputedStyle(document.documentElement).getPropertyValue('--accent-rgb').trim();
            if (rgb) return `rgba(${rgb}, 0.70)`;
        } catch(e) {}
        return 'rgba(255,255,255,0.50)';
    }

    _parseColor(rgba) {
        const m = rgba.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
        return m ? [+m[1], +m[2], +m[3]] : [255, 255, 255];
    }

    resize() {
        // Cap DPR at 1 in performance mode, 1.5 in quality mode
        const dpr = Math.min(window.devicePixelRatio || 1, this.performanceMode ? 1.0 : 1.5);
        this.canvas.width  = window.innerWidth  * dpr;
        this.canvas.height = window.innerHeight * dpr;
        // Get fresh context after resize (some Android WebViews lose it)
        this.ctx = this.canvas.getContext('2d', { alpha: true });
        this.ctx.scale(dpr, dpr);
        this.init();
    }

    init() {
        const W = window.innerWidth, H = window.innerHeight;

        // ── PARTICLES — simple dots with pulse ─────────────────────
        this.particles = [];
        // Performance mode: larger dots to compensate for lower count
        const sizeBase = this.performanceMode ? 1.8 : 0.8;
        const sizeRange = this.performanceMode ? 3.5 : 2.5;
        for (let i = 0; i < this.particleCount; i++) {
            this.particles.push({
                x: Math.random() * W,
                y: Math.random() * H,
                size: Math.random() * sizeRange + sizeBase,
                speedX: (Math.random() - 0.5) * 0.40,
                speedY: (Math.random() - 0.5) * 0.40,
                opacity: Math.random() * 0.45 + 0.45,
                pulsePhase: Math.random() * Math.PI * 2,
                pulseSpeed: 0.018 + Math.random() * 0.022,
                // Perf mode: 50% bright (cheap white-tinted dot, no gradient)
                // Quality mode: 30% bright (expensive radial gradient halo)
                isBright: this.performanceMode
                    ? (Math.random() > 0.50)
                    : (Math.random() > 0.70)
            });
        }

        this.shootingStars = [];
        this.sparkles = [];
    }

    // ── SHOOTING STARS — only in quality mode ─────────────────────
    _spawnShootingStar(W, H) {
        if (this.performanceMode) return; // disabled in performance mode
        if (Math.random() > 0.010) return;
        const x = Math.random() * W;
        const y = -10;
        const angle = Math.PI / 2 + (Math.random() - 0.5) * 0.6;
        const speed = 5 + Math.random() * 6;
        this.shootingStars.push({
            x, y,
            vx: speed * Math.cos(angle),
            vy: speed * Math.sin(angle),
            length: 55 + Math.random() * 70,
            maxOpacity: 0.60 + Math.random() * 0.28,
            age: 0,
            maxAge: 40 + Math.floor(Math.random() * 25)
        });
    }

    _drawShootingStars(W, H, rgb) {
        const ctx = this.ctx;
        this.shootingStars = this.shootingStars.filter(s => s.age < s.maxAge);
        for (const s of this.shootingStars) {
            const progress = s.age / s.maxAge;
            let alpha = s.maxOpacity;
            if (progress < 0.15) alpha *= progress / 0.15;
            else if (progress > 0.55) alpha *= 1 - (progress - 0.55) / 0.45;
            const spd = Math.sqrt(s.vx * s.vx + s.vy * s.vy);
            const tailX = s.x - (s.vx / spd) * s.length;
            const tailY = s.y - (s.vy / spd) * s.length;
            const grd = ctx.createLinearGradient(tailX, tailY, s.x, s.y);
            grd.addColorStop(0, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0)`);
            grd.addColorStop(0.7, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${(alpha*0.4).toFixed(3)})`);
            grd.addColorStop(1, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${alpha.toFixed(3)})`);
            ctx.beginPath();
            ctx.moveTo(tailX, tailY);
            ctx.lineTo(s.x, s.y);
            ctx.strokeStyle = grd;
            ctx.lineWidth = 1.5;
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(s.x, s.y, 2, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(255,255,255,${(alpha * 0.90).toFixed(3)})`;
            ctx.fill();
            s.x += s.vx;
            s.y += s.vy;
            s.age++;
        }
    }

    // ── SPARKLES — only in quality mode ───────────────────────────
    _spawnSparkle(W, H) {
        if (this.performanceMode) return; // disabled in performance mode
        if (Math.random() > 0.035) return;
        this.sparkles.push({
            x: Math.random() * W,
            y: Math.random() * H,
            size: 1.5 + Math.random() * 2.5,
            age: 0,
            maxAge: 28 + Math.floor(Math.random() * 20),
            maxOp: 0.65 + Math.random() * 0.25
        });
    }

    _drawSparkles(rgb) {
        const ctx = this.ctx;
        this.sparkles = this.sparkles.filter(s => s.age < s.maxAge);
        for (const s of this.sparkles) {
            const progress = s.age / s.maxAge;
            const alpha = progress < 0.3
                ? s.maxOp * (progress / 0.3)
                : s.maxOp * (1 - (progress - 0.3) / 0.7);
            ctx.save();
            ctx.translate(s.x, s.y);
            ctx.strokeStyle = `rgba(255,255,255,${alpha.toFixed(3)})`;
            ctx.lineWidth = 0.8;
            const len = s.size * 2.2;
            ctx.beginPath();
            ctx.moveTo(-len, 0); ctx.lineTo(len, 0);
            ctx.moveTo(0, -len); ctx.lineTo(0, len);
            ctx.stroke();
            ctx.restore();
            ctx.beginPath();
            ctx.arc(s.x, s.y, s.size * 0.6, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(255,255,255,${alpha.toFixed(3)})`;
            ctx.fill();
            s.age++;
        }
    }

    animate(currentTime = 0) {
        this.animationId = requestAnimationFrame((t) => this.animate(t));
        // Pause rendering when page is not visible (battery/CPU save)
        if (document.hidden) return;
        this.frameCount++;

        const W = window.innerWidth, H = window.innerHeight;
        const ctx = this.ctx;
        ctx.clearRect(0, 0, W, H);

        // Read theme color every 90 frames — or more often in quality mode
        const colorInterval = this.performanceMode ? 120 : 60;
        if (this.frameCount % colorInterval === 0 || !this.currentColor) {
            this.currentColor = this._readThemeColor();
        }
        const rgb = this._parseColor(this.currentColor);

        // ── Particles ──────────────────────────────────────────────
        const particles = this.particles;
        const len = particles.length;
        // Mix accent color with white so particles are bright enough to see against dark cards
        // r2/g2/b2 is a white-blended version for the dot center
        const r2 = Math.round(rgb[0] * 0.5 + 255 * 0.5);
        const g2 = Math.round(rgb[1] * 0.5 + 255 * 0.5);
        const b2 = Math.round(rgb[2] * 0.5 + 255 * 0.5);

        if (this.performanceMode) {
            // PERFORMANCE PATH: simple arc dots, solid accent-white color
            for (let i = 0; i < len; i++) {
                const p = particles[i];
                p.x += p.speedX;
                p.y += p.speedY;
                if (p.x < 0) p.x = W;
                if (p.x > W) p.x = 0;
                if (p.y < 0) p.y = H;
                if (p.y > H) p.y = 0;
                p.pulsePhase += p.pulseSpeed;
                const op = Math.max(0.40, p.opacity + Math.sin(p.pulsePhase) * 0.18);
                ctx.globalAlpha = op;
                // Alternate between accent color and white-tinted for variety
                ctx.fillStyle = p.isBright
                    ? `rgb(${r2},${g2},${b2})`
                    : `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
                ctx.beginPath();
                ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.globalAlpha = 1;
        } else {
            // QUALITY PATH: glowing halos + white bright centers
            for (let i = 0; i < len; i++) {
                const p = particles[i];
                p.x += p.speedX;
                p.y += p.speedY;
                if (p.x < 0) p.x = W;
                if (p.x > W) p.x = 0;
                if (p.y < 0) p.y = H;
                if (p.y > H) p.y = 0;
                p.pulsePhase += p.pulseSpeed;
                const op = Math.max(0.35, p.opacity + Math.sin(p.pulsePhase) * 0.18);

                if (p.isBright) {
                    // Glowing star: colored halo + bright white center
                    const haloR = p.size * 7;
                    const hGrd = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, haloR);
                    hGrd.addColorStop(0, `rgba(${r2},${g2},${b2},${(op * 0.85).toFixed(3)})`);
                    hGrd.addColorStop(0.4, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${(op * 0.35).toFixed(3)})`);
                    hGrd.addColorStop(1, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0)`);
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, haloR, 0, Math.PI * 2);
                    ctx.fillStyle = hGrd;
                    ctx.fill();
                    // Bright white dot center
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, p.size * 1.0, 0, Math.PI * 2);
                    ctx.fillStyle = `rgba(255,255,255,${(op * 0.98).toFixed(3)})`;
                    ctx.fill();
                } else {
                    // Plain accent dot
                    ctx.globalAlpha = op;
                    ctx.fillStyle = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.globalAlpha = 1;
                }
            }
        }

        // ── Shooting stars + sparkles (quality mode only) ──────────
        if (!this.performanceMode) {
            this._spawnShootingStar(W, H);
            this._drawShootingStars(W, H, rgb);
            this._spawnSparkle(W, H);
            this._drawSparkles(rgb);
        }
    }

    destroy() {
        if (this.animationId) cancelAnimationFrame(this.animationId);
    }
}
// ============================================
// UI UTILITIES & MANAGERS
// ============================================

class UIManager {
    static showBanner(message, type = 'error') {
        const banner = document.getElementById(`${type}Banner`);
        if (!banner) return;
        
        const textEl = banner.querySelector('.banner-text');
        if (textEl) textEl.textContent = message;
        banner.style.display = 'flex';
        
        const closeBtn = banner.querySelector('.banner-close');
        const handleClose = () => {
            banner.style.display = 'none';
            closeBtn.removeEventListener('click', handleClose);
        };
        closeBtn.addEventListener('click', handleClose, { once: true });
        
        setTimeout(() => {
            if (banner.style.display === 'flex') banner.style.display = 'none';
        }, 5000);
    }
    
    static updateStatus(text, type = 'ready') {
        if (_statusText) _statusText.textContent = text;
        if (_statusDot) {
            _statusDot.className = 'status-dot';
            if (type === 'active') _statusDot.classList.add('active');
        }
    }
}

class ConfirmDialog {
    static show(title, message, icon = '⚠️') {
        return new Promise((resolve) => {
            const dialog = document.getElementById('confirmDialog');
            if (!dialog) {
                resolve(confirm(message));
                return;
            }
            
            const titleEl = document.getElementById('confirmTitle');
            const messageEl = document.getElementById('confirmMessage');
            const iconEl = document.getElementById('confirmIcon');
            
            if (titleEl) titleEl.textContent = title;
            if (messageEl) messageEl.textContent = message;
            if (iconEl) iconEl.textContent = icon;
            
            const okBtn = document.getElementById('confirmOk');
            const cancelBtn = document.getElementById('confirmCancel');
            
            dialog.style.display = 'block';
            
            const cleanup = () => {
                dialog.style.display = 'none';
                okBtn.replaceWith(okBtn.cloneNode(true));
                cancelBtn.replaceWith(cancelBtn.cloneNode(true));
            };
            
            document.getElementById('confirmOk').onclick = () => { cleanup(); resolve(true); };
            document.getElementById('confirmCancel').onclick = () => { cleanup(); resolve(false); };
            const overlay = dialog.querySelector('.modal-overlay');
            if (overlay) overlay.onclick = () => { cleanup(); resolve(false); };
        });
    }
}

// ============================================
// CONSTANTS & TRANSLATIONS
// ============================================

const MOD_ID = "adreno_gpu_driver_unified";
const SD_ROOT = "/sdcard/Adreno_Driver";
const SD_CONFIG = `${SD_ROOT}/Config`;
const SD_LANG = `${SD_ROOT}/Languages`;
const SD_DOCS = `${SD_ROOT}/Documentation`;
const SD_STATS = `${SD_ROOT}/Statistics/stats.json`;

let MOD_PATH = "";
let MOD_WEB_LANG = ""; 
let MOD_DOCS = "";     
let currentLangCode = "en";
let currentTranslations = {};
let particleBg = null;

// Statistics tracking
let statistics = {
    configChanges: 0,
    fixesApplied: 0,
    spoofCount: 0
};

// Cached DOM elements — populated in DOMContentLoaded
let _logArea    = null;
let _logCount   = null;
let _spinner    = null;
let _overlay    = null;
let _statConfig = null;
let _statFixes  = null;
let _statSpoof  = null;
let _navItems   = null;
let _statusText = null;
let _statusDot  = null;

const DEFAULT_EN = {
    title: "Adreno", 
    subtitle: "Manager",
    tabHome: "Home", 
    tabConfig: "Config", 
    tabUtils: "Utils", 
    tabData: "Data",
    statusReady: "Ready",
    welcomeTitle: "Welcome Back",
    welcomeSubtitle: "Manage your GPU driver settings with precision",
    sysInfo: "System Overview", 
    sysInfoSub: "Device information and status",
    device: "Device", 
    android: "Android", 
    gpu: "GPU Model", 
    driverVer: "Driver Version", 
    modVer: "Module Version",
    hardwareTitle: "Hardware Details", 
    hardwareSub: "Processor and GPU information",
    processorLabel: "Processor", 
    socLabel: "SoC", 
    cpuLabel: "CPU", 
    socCodenameLabel: "SoC Codename", 
    architectureLabel: "Architecture",
    gpuSectionLabel: "GPU", 
    gpuModelLabel: "GPU Model", 
    gpuVendorLabel: "Vendor",
    rendererLabel: "Renderer", 
    driverVersionLabel: "Driver Version",
    langName: "Language", 
    langDesc: "Choose interface language",
    langSystem: "System",
    config: "Driver Settings",
    configTitle: "Driver Settings", 
    configSub: "Module configuration and options",
    pltName: "PLT Patching",
    pltDesc: "Enabled automatically when gpu++.so is detected in the driver",
    pltSub: "Auto-enabled if gpu++.so is present in driver",
    qglName: "QGL Config",
    qglDesc: "Configure Qualcomm Graphics Library for Adreno GPUs.Instead use lyb kernel manager for better control and it supports all socs",
    qglSub: "Reminder: Better to use lyb kernel manager",
    edit: "Edit",
    armName: "ARM64 Optimization",
    armDesc: "Remove 32-bit libraries for unsupported ROMs",
    verboseName: "Verbose Logging",
    verboseDesc: "Enable detailed logs for troubleshooting",
    renderName: "Rendering Mode",
    renderDesc: "Default rendering backend with balanced performance",
    renderDescSkiaVK: "Skia with Vulkan backend - Better performance on modern GPUs",
    renderDescSkiaGL: "Skia with OpenGL backend - Better compatibility",
    renderDescSkiaVKAll: "Aggressive SkiaVK with forced app restarts - Maximum performance",
    renderNormal: "Normal",
    renderStatusLabel: "Live Render Status",
    hwuiRendererLabel: "HWUI Renderer",
    renderEngineLabel: "Render Engine",
    useVulkanLabel: "Vulkan Prop",
    renderStatusHint: "Renderer props written to system.prop (persistent) + applied live via resetprop — takes full effect on next reboot",
    // Game Exclusion List
    gameExclTitle: "Game Exclusion List",
    gameExclSub: "⚠️ Only add a game if it CRASHES in skiavk or skiavk_all mode — remove it if it runs fine",
    gameExclDesc: "Only add a game here if it crashes immediately when skiavk or skiavk_all is active (black screen, instant force-close, GPU fault). If the game works fine in skiavk mode, do NOT add it — adding it unnecessarily keeps the game on the older GL renderer and wastes daemon protection slots. Remove any game that no longer crashes.",
    gameExclBadge: "Shared · post-fs-data & service",
    gameExclAdd: "Add Package",
    gameExclPlaceholder: "e.g. com.example.game or com.example.*",
    gameExclAddBtn: "Add",
    gameExclRemove: "Remove",
    gameExclEmpty: "No packages in exclusion list",
    gameExclSave: "Save List",
    gameExclSaved: "Game exclusion list saved",
    gameExclSaveError: "Failed to save exclusion list",
    gameExclReset: "Reset to Defaults",
    gameExclResetConfirm: "Reset game exclusion list to factory defaults?",
    gameExclCount: "packages",
    gameExclWildcard: "Wildcards supported (e.g. com.epicgames.*)",
    gameExclWhyTitle: "When to add / remove a game",
    gameExclWhyBody: "ADD a game only if it crashes in skiavk/skiavk_all mode: the crash is caused by a dual-VkDevice conflict — apps that create their own VkDevice (game engines using Vulkan directly, e.g. UE4, custom Vulkan) conflict with HWUI holding a second one, which custom Adreno drivers cannot handle → SIGSEGV. The compat daemon switches HWUI to skiagl within ~1s of detecting the app, resolving the conflict. REMOVE a game if it runs fine in skiavk — it does not need to be here, and keeping it unnecessarily delays its transition to the Vulkan renderer.",
    applyNowTitle: "Apply Render Mode Now",
    applyNowDesc: "Apply via resetprop instantly — no reboot needed. Kill & reopen apps to see effect.",
    applyNow: "Apply Now",
    // Game Exclusion Daemon toggle
    daemonName: "Game Exclusion Daemon",
    daemonDesc: "Auto-switches HWUI to skiagl when a native-Vulkan game is detected. Prevents dual-VkDevice crashes in skiavk mode.",
    daemonSub: "Required for apps that have problems in skiavk rendering",
    save: "Save & Reboot",
    saveRebootInfo: "Changes will be applied after saving and rebooting your device. Make sure to backup your current configuration before making changes.",
    resetDefaults: "Reset to Defaults",
    msgConfigSaved: "✓ Configuration saved successfully",
    utilsTitle: "Tools & Utilities",
    utilsSub: "GPU tools and system maintenance",
    gpuSpoofLabel: "GPU Spoofer", 
    gpuSpoofDesc: "Modify GPU identification",
    spoofOriginalId: "ORIGINAL ID",
    spoofTargetId: "TARGET ID",
    spoofSelectSource: "Select Source",
    applyPatch: "Apply Patch",
    fixesLabel: "Quick Fixes",
    fixCamera: "Camera",
    fixCam: "Camera",
    fixRecorder: "Screen Recorder",
    fixRec: "Screen Recorder",
    fixNight: "Night Mode Fix",
    maintenanceTitle: "System Maintenance",
    clearGPUCacheTitle: "Clear GPU Caches", 
    clearGPUCacheDesc: "Remove shader and graphics caches",
    clearGPUCache: "Clear",
    trimStorageTitle: "Trim Storage", 
    trimStorageDesc: "Optimize filesystem performance",
    trimStorage: "Optimize",
    clearCustomLangTitle: "Clear Custom Language", 
    clearCustomLangDesc: "Remove custom.json",
    clearCustomLang: "Clear",
    msgSpoofApplied: "✓ GPU spoof applied",
    msgSpoofSuccess: "Spoof Applied! Reboot required.",
    msgSpoofFail: "Spoof Failed or Invalid Input.",
    msgFixApplied: "✓ Fix applied successfully",
    msgTrimComplete: "✓ Storage trim complete",
    fixCameraWarningTitle: "Camera Fix",
    fixCameraWarning: "This will remove the following libraries:\n\n• libCB.so\n• libgpudataproducer.so\n• libkcl.so\n• libkernelmanager.so\n• libllvm-qcom.so\n• libOpenCL.so\n• libOpenCL_adreno.so\n\nNote: This can only fix issues caused by these module libraries. If the problem persists, it may not be module-related.\n\nTo restore these libraries, you need to reflash the module.\n\nContinue?",
    fixRecorderWarningTitle: "Screen Recorder Fix",
    fixRecorderWarning: "This will remove the following libraries:\n\n• libC2D2.so\n• libc2d30_bltlib.so\n• libc2dcolorconvert.so\n\nNote: This can only fix issues caused by these module libraries. If the problem persists, it may not be module-related.\n\nTo restore these libraries, you need to reflash the module.\n\nContinue?",
    fixNightWarningTitle: "Night Mode Fix",
    fixNightWarning: "This will remove the following library:\n\n• libsnapdragon_color_manager.so\n\nNote: This can only fix issues caused by this module library. If the problem persists, it may not be module-related.\n\nTo restore this library, you need to reflash the module.\n\nContinue?",
    dataSection: "Data & Logs",
    dataTitle: "Data & Logs", 
    dataSub: "System logs and statistics",
    statsTitle: "Statistics", 
    statsSub: "Usage metrics",
    statConfigs: "Configs",
    statFixes: "Fixes",
    statSpoofs: "Spoofs",
    configChanges: "CONFIGS", 
    fixesApplied: "FIXES", 
    spoofCount: "SPOOFS",
    logsTitle: "System Logs", 
    logsSub: "Real-time activity monitor",
    logs: "System Logs",
    clearLogs: "Clear", 
    copyLogs: "Copy",
    copy: "Copy", 
    exportLogs: "Export",
    logsConnected: "Connected",
    logsLines: "Lines:",
    autoBackupTitle: "Auto-Backup Info",
    autoBackupSub: "Configuration persistence",
    autoBackupInfoTitle: "Automatic Configuration Backup",
    autoBackupPath1: "All your settings are automatically saved to:",
    autoBackupPath2: "/sdcard/Adreno_Driver/",
    autoBackupNote: "This folder is directly connected to the module and persists across:",
    autoBackupBullet1: "Module updates",
    autoBackupBullet2: "Module reinstalls",
    autoBackupBullet3: "System reboots",
    autoBackupManualTitle: "Manual Configuration Management",
    autoBackupManualDesc: "If you want to reset or modify your configuration before reinstalling:",
    autoBackupStep1: "1. Navigate to /sdcard/Adreno_Driver/Config/",
    autoBackupStep2: "2. Delete or modify adreno_config.txt",
    autoBackupStep3: "3. Reinstall module for fresh configuration",
    aboutAppName: "Adreno Manager",
    aboutFeatures: "Features",
    feature1: "PLT Patching for Banch++",
    feature2: "QGL Configuration",
    feature3: "ARM64 Optimization",
    feature4: "Rendering Options (Vulkan/OpenGL)",
    feature5: "GPU Cache Management",
    feature6: "Storage Optimization",
    feature7: "Auto-Backup System",
    feature8: "Hardware Detection",
    aboutCredit: "Created with ❤️ for the Adreno community",
    docTitle: "Documentation", 
    docModalSub: "User guide and manual",
    docTranslate: "Translate",
    qglModalTitle: "QGL Editor",
    qglModalSub: "Qualcomm Graphics Library Configuration",
    qglSave: "Save",
    qglFormat: "Format",
    qglReset: "Reset",
    qglLines: "Lines:",
    qglClose: "Close",
    msgQGLSaved: "✅ QGL Config Saved (Persistent)",
    msgQGLFail: "❌ Failed to save QGL Config",
    confirmCancel: "Cancel",
    confirmOk: "Confirm",
    connected: "Connected", 
    loading: "Loading...",
    restoreOriginal: "Restore Original",
    restoreOriginalDesc: "Restore factory-stock libgsl.so from backup",
    themePickerTitle: "🎨 Choose Theme",
    themePickerSub: "Saved to configuration automatically",
    displayStyleLabel: "Display Style",
    colorModeGlass: "Glass",
    colorModeGlassDesc: "Frosted blur",
    colorModeBlur: "Blur",
    colorModeBlurDesc: "Heavy blur",
    colorModeClear: "Clear",
    colorModeClearDesc: "See-through",
    colorModeVivid: "Vivid",
    colorModeVividDesc: "Full color",
    visualEffectsLabel: "Visual Effects",
    qualityModeOn: "Quality Mode",
    qualityModeOnDesc: "All effects enabled",
    qualityModeOff: "Performance Mode",
    qualityModeOffDesc: "Smooth on all devices",
    qualityHintOn: "Aurora, animations & blur active — disable if device lags",
    qualityHintOff: "Enable for aurora, animations & backdrop blur — may lag on older devices",
    swatchPurple: "Purple",
    swatchAmber: "Amber",
    swatchOcean: "Ocean",
    swatchRose: "Rose",
    swatchForest: "Forest",
    // ── Custom Driver Changes ──────────────────────────────────────
    customDriverLabel: "Custom Driver Changes",
    customDriverDesc: "Spoof or make VKOnly for any driver",
    customDriverInfo: "Apply custom GPU spoofs or create Vulkan-only driver builds from any driver files.",
    customDriverOpen: "Open Custom Driver Tools",
    customDriverModalTitle: "Custom Driver Tools",
    customDriverModalSub: "Advanced driver modification",
    customDriverChooseFeature: "What do you want to do?",
    customDriverChooseFeatureSub: "Select the operation to perform on your driver files.",
    customDriverSpoofBtn: "🎭 Custom GPU Spoof",
    customDriverSpoofBtnDesc: "Spoof GPU model IDs in any libgsl.so",
    customDriverVKOnlyBtn: "⚡ Make VKOnly",
    customDriverVKOnlyBtnDesc: "Keep only a driver's Vulkan libraries via patching to use with another driver",
    customDriverLibMode: "Does the driver have lib and lib64?",
    customDriverLibModeSub: "Select which directories are present in your driver.",
    customDriverLibOnly: "lib only",
    customDriverLib64Only: "lib64 only",
    customDriverBoth: "Both lib + lib64",
    customDriverEnterPath: "Enter driver lib path",
    customDriverEnterPathSub: "Provide the full path to the driver lib folder on your device.",
    customDriverLibPathLabel: "lib folder path",
    customDriverLib64PathLabel: "lib64 folder path",
    customDriverPathPlaceholder: "e.g. /sdcard/MyDriver/system/vendor/lib",
    customDriverPath64Placeholder: "e.g. /sdcard/MyDriver/system/vendor/lib64",
    customDriverScanBtn: "🔍 Scan GPU Models",
    customDriverScanning: "Scanning GPU models...",
    customDriverScanResults: "GPU Models Found",
    customDriverScanResultsSub: "Select one or more source models to spoof",
    customDriverSelectSources: "Select source GPU models:",
    customDriverTargetLabel: "Spoof all selected → Target GPU model:",
    customDriverTargetPlaceholder: "e.g. 750",
    customDriverApplySpoof: "✅ Apply This Spoof",
    customDriverMoreSpoofs: "Do you want to spoof more models?",
    customDriverMoreSpoofsSub: "You can map another set of source models to a different target.",
    customDriverYesMore: "Yes, spoof more",
    customDriverNoDone: "No, I'm done",
    customDriverSpoofComplete: "Spoof applied! Flash the modified driver to apply it.",
    customDriverFlashToApply: "Flash the spoofed driver to your device for changes to take effect. Do NOT simply reboot — the modified file must be flashed first.",
    customDriverBackupInfo: "Backup of original libgsl.so saved to:",
    customDriverGSLMixWarning: "⚠️ Critical: Do NOT mix this libgsl.so with any other driver. Only pair it with the exact driver it came from. Using it with a different driver WILL cause a bootloop.",
    customDriverVendorWarning: "⚠️ Safety: Do NOT enter a path pointing to the live /vendor/ or /system/ partition. Never spoof libgsl.so in a live environment — it WILL cause a bootloop. Always work on driver files copied to /sdcard/.",
    customDriverVulkanHwNote: "Note: vulkan.adreno.so may be located in lib64/ or lib64/hw/ — the tool checks both.",
    customDriverNoModels: "No Adreno models found in this file. Make sure you selected the correct libgsl.so.",
    customDriverPathNotFound: "Path not found. Please check and re-enter.",
    customDriverLibgslNotFound: "libgsl.so not found in the specified path.",
    customDriverVKOnlyTitle: "Select Driver Files",
    customDriverVKOnlyInstructions: "Select the 5 required files from the driver's",
    customDriverVKOnlyFileList: "Required files:",
    customDriverVKOnlyNote: "The first 4 will be renamed (lib→not). All 5 will have internal references patched.",
    customDriverVKOnlySelectAll: "Select all 5 files",
    customDriverVKOnlyProcess: "⚡ Apply VKOnly",
    customDriverVKOnlyOutput: "Modified files will be saved to:",
    customDriverVKOnlyComplete: "VKOnly applied! Files saved to /sdcard/Adreno_Driver/VKOnly/",
    customDriverVKOnlyFail: "VKOnly failed. Check logs for details.",
    customDriverVKOnlyMissingFiles: "Please select all 5 required files.",
    customDriverCurrentTurn: "Processing:",
    customDriverNextLib64: "Proceed to lib64",
    wizardBack: "Back",
    wizardNext: "Next",
    customDriverSpoofSafetyError: "Source and target must have the same digit count to avoid ELF corruption!"
};

const BUILTIN_ZH_CN = {
    title: "Adreno", 
    subtitle: "管理器",
    tabHome: "主页", 
    tabConfig: "配置", 
    tabUtils: "工具", 
    tabData: "数据",
    statusReady: "就绪",
    welcomeTitle: "欢迎回来", 
    welcomeSubtitle: "精确管理您的GPU驱动程序设置",
    sysInfo: "系统概述", 
    sysInfoSub: "设备信息和状态",
    device: "设备", 
    android: "安卓", 
    gpu: "GPU型号",
    driverVer: "驱动版本", 
    modVer: "模块版本",
    hardwareTitle: "硬件详情", 
    hardwareSub: "处理器和GPU信息",
    processorLabel: "处理器", 
    socLabel: "SoC", 
    cpuLabel: "CPU",
    socCodenameLabel: "SoC代号", 
    architectureLabel: "架构",
    gpuSectionLabel: "GPU", 
    gpuModelLabel: "GPU型号", 
    gpuVendorLabel: "供应商",
    rendererLabel: "渲染器", 
    driverVersionLabel: "驱动版本",
    langName: "语言", 
    langDesc: "选择界面语言",
    langSystem: "系统",
    config: "驱动设置",
    configTitle: "驱动设置", 
    configSub: "模块配置和选项",
    pltName: "PLT补丁",
    pltDesc: "当驱动中检测到gpu++.so时自动启用",
    pltSub: "若驱动中存在gpu++.so则自动启用",
    qglName: "QGL配置",
    qglDesc: "为 Adreno GPU 配置 Qualcomm 图形库，建议改用 Lyb 内核管理器，以获得更精细的控制，并支持所有 SoC",
    qglSub: "提醒：最好使用 lyb Kernel Manager",
    edit: "编辑",
    armName: "ARM64优化",
    armDesc: "移除32位库，用于不支持32位的ROM",
    verboseName: "详细日志",
    verboseDesc: "启用详细日志以进行故障排除",
    renderName: "渲染模式",
    renderDesc: "默认渲染后端，性能均衡",
    renderDescSkiaVK: "Skia + Vulkan 后端 - 现代GPU性能更佳",
    renderDescSkiaGL: "Skia + OpenGL 后端 - 兼容性更好",
    renderDescSkiaVKAll: "激进SkiaVK模式，强制重启应用 - 最高性能",
    renderNormal: "正常",
    renderStatusLabel: "实时渲染状态",
    hwuiRendererLabel: "HWUI 渲染器",
    renderEngineLabel: "渲染引擎",
    useVulkanLabel: "Vulkan 属性",
    renderStatusHint: "渲染器属性已写入 system.prop（持久化）并通过 resetprop 实时应用 — 重启后完全生效",
    // Game Exclusion List
    gameExclTitle: "游戏排除列表",
    gameExclSub: "⚠️ 仅在游戏于 skiavk 或 skiavk_all 模式下崩溃时才添加 — 正常运行则请移除",
    gameExclDesc: "仅在游戏于 skiavk 或 skiavk_all 模式下立即崩溃时（黑屏、即时强制关闭、GPU 故障）才添加到此列表。如果游戏在 skiavk 模式下运行正常，请勿添加 — 不必要地添加会使该游戏继续使用旧版 GL 渲染器，并浪费守护进程保护槽位。若游戏已不再崩溃，请将其移除。",
    gameExclBadge: "共享 · post-fs-data 和 service",
    gameExclAdd: "添加包名",
    gameExclPlaceholder: "例如 com.example.game 或 com.example.*",
    gameExclAddBtn: "添加",
    gameExclRemove: "删除",
    gameExclEmpty: "排除列表为空",
    gameExclSave: "保存列表",
    gameExclSaved: "游戏排除列表已保存",
    gameExclSaveError: "保存排除列表失败",
    gameExclReset: "恢复默认",
    gameExclResetConfirm: "将游戏排除列表重置为出厂默认值？",
    gameExclCount: "个包",
    gameExclWildcard: "支持通配符（例如 com.epicgames.*）",
    gameExclWhyTitle: "何时添加或移除游戏",
    gameExclWhyBody: "仅在游戏于 skiavk/skiavk_all 模式下崩溃时才添加：崩溃由双 VkDevice 冲突引起 — 直接使用 Vulkan 的应用（自定义 Vulkan 引擎，如 UE4 等）与 HWUI 同时创建 VkDevice，自定义 Adreno 驱动无法处理 → SIGSEGV。兼容守护进程会在检测到应用后约 1 秒内将 HWUI 切换为 skiagl 解决冲突。若游戏在 skiavk 模式下运行正常 — 请将其移除，无需保留在此列表中。",
    applyNowTitle: "立即应用渲染模式",
    applyNowDesc: "通过 resetprop 即时应用 — 无需重启。重启应用以查看效果。",
    applyNow: "立即应用",
    // Game Exclusion Daemon toggle
    daemonName: "游戏排除守护进程",
    daemonDesc: "检测到原生 Vulkan 游戏时自动将 HWUI 切换为 skiagl。防止 skiavk 模式下的双 VkDevice 崩溃。",
    daemonSub: "适用于在skiavk渲染模式下存在问题的应用",
    save: "保存并重启",
    saveRebootInfo: "更改将在保存并重启设备后生效。在进行更改之前，请务必备份当前配置。",
    resetDefaults: "恢复默认值",
    msgConfigSaved: "✓ 配置保存成功",
    utilsTitle: "工具和实用程序",
    utilsSub: "GPU工具和系统维护",
    gpuSpoofLabel: "GPU欺骗器", 
    gpuSpoofDesc: "修改GPU识别信息",
    spoofOriginalId: "原始ID",
    spoofTargetId: "目标ID",
    spoofSelectSource: "选择来源",
    applyPatch: "应用补丁",
    fixesLabel: "快速修复",
    fixCamera: "相机",
    fixCam: "相机",
    fixRecorder: "屏幕录制",
    fixRec: "屏幕录制",
    fixNight: "夜间模式修复",
    maintenanceTitle: "系统维护",
    clearGPUCacheTitle: "清除GPU缓存", 
    clearGPUCacheDesc: "移除着色器和图形缓存",
    clearGPUCache: "清除",
    trimStorageTitle: "整理存储", 
    trimStorageDesc: "优化文件系统性能",
    trimStorage: "优化",
    clearCustomLangTitle: "清除自定义语言", 
    clearCustomLangDesc: "移除custom.json",
    clearCustomLang: "清除",
    msgSpoofApplied: "✓ GPU欺骗已应用",
    msgSpoofSuccess: "欺装已应用! 需要重启",
    msgSpoofFail: "欺装失败或输入无效",
    msgFixApplied: "✓ 修复应用成功",
    msgTrimComplete: "✓ 存储整理完成",
    fixCameraWarningTitle: "相机修复",
    fixCameraWarning: "这将删除以下库文件：\n\n• libCB.so\n• libgpudataproducer.so\n• libkcl.so\n• libkernelmanager.so\n• libllvm-qcom.so\n• libOpenCL.so\n• libOpenCL_adreno.so\n\n注意：这只能修复由这些模块库引起的问题。如果问题仍然存在，可能与模块无关。\n\n要恢复这些库文件，您需要重新刷入模块。\n\n继续？",
    fixRecorderWarningTitle: "屏幕录制修复",
    fixRecorderWarning: "这将删除以下库文件：\n\n• libC2D2.so\n• libc2d30_bltlib.so\n• libc2dcolorconvert.so\n\n注意：这只能修复由这些模块库引起的问题。如果问题仍然存在，可能与模块无关。\n\n要恢复这些库文件，您需要重新刷入模块。\n\n继续？",
    fixNightWarningTitle: "夜间模式修复",
    fixNightWarning: "这将删除以下库文件：\n\n• libsnapdragon_color_manager.so\n\n注意：这只能修复由此模块库引起的问题。如果问题仍然存在，可能与模块无关。\n\n要恢复此库文件，您需要重新刷入模块。\n\n继续？",
    dataSection: "数据与日志",
    dataTitle: "数据和日志", 
    dataSub: "系统日志和统计信息",
    statsTitle: "统计信息", 
    statsSub: "使用指标",
    statConfigs: "配置",
    statFixes: "修复",
    statSpoofs: "欺骗",
    configChanges: "配置", 
    fixesApplied: "修复", 
    spoofCount: "欺骗",
    logsTitle: "系统日志", 
    logsSub: "实时活动监视器",
    logs: "系统日志",
    clearLogs: "清除", 
    copyLogs: "复制",
    copy: "复制", 
    exportLogs: "导出",
    logsConnected: "已连接",
    logsLines: "行数：",
    autoBackupTitle: "自动备份信息",
    autoBackupSub: "配置持久化",
    autoBackupInfoTitle: "自动配置备份",
    autoBackupPath1: "您的所有设置会自动保存到：",
    autoBackupPath2: "/sdcard/Adreno_Driver/",
    autoBackupNote: "此文件夹直接连接到模块，并在以下情况下保持不变：",
    autoBackupBullet1: "模块更新",
    autoBackupBullet2: "模块重新安装",
    autoBackupBullet3: "系统重启",
    autoBackupManualTitle: "手动配置管理",
    autoBackupManualDesc: "如果您想在重新安装前重置或修改配置：",
    autoBackupStep1: "1. 导航到 /sdcard/Adreno_Driver/Config/",
    autoBackupStep2: "2. 删除或修改 adreno_config.txt",
    autoBackupStep3: "3. 重新安装模块以获得全新配置",
    aboutAppName: "Adreno管理器",
    aboutFeatures: "功能特性",
    feature1: "Banch++的PLT补丁",
    feature2: "QGL配置",
    feature3: "ARM64优化",
    feature4: "渲染选项（Vulkan/OpenGL）",
    feature5: "GPU缓存管理",
    feature6: "存储优化",
    feature7: "自动备份系统",
    feature8: "硬件检测",
    aboutCredit: "用❤️为Adreno社区创建",
    docTitle: "文档", 
    docModalSub: "用户指南和手册",
    docTranslate: "翻译",
    qglModalTitle: "QGL编辑器",
    qglModalSub: "高通图形库配置",
    qglSave: "保存",
    qglFormat: "格式化",
    qglReset: "重置",
    qglLines: "行数：",
    qglClose: "关闭",
    msgQGLSaved: "✅ QGL配置已保存（持久化）",
    msgQGLFail: "❌ QGL配置保存失败",
    confirmCancel: "取消",
    confirmOk: "确认",
    connected: "已连接", 
    loading: "加载中...",
    restoreOriginal: "恢复原始",
    restoreOriginalDesc: "从备份恢复出厂libgsl.so",
    themePickerTitle: "🎨 选择主题",
    themePickerSub: "自动保存到配置",
    displayStyleLabel: "显示风格",
    colorModeGlass: "玻璃",
    colorModeGlassDesc: "毛玻璃模糊",
    colorModeBlur: "模糊",
    colorModeBlurDesc: "重度模糊",
    colorModeClear: "透明",
    colorModeClearDesc: "穿透效果",
    colorModeVivid: "鲜艳",
    colorModeVividDesc: "全彩效果",
    visualEffectsLabel: "视觉效果",
    qualityModeOn: "质量模式",
    qualityModeOnDesc: "所有效果已启用",
    qualityModeOff: "性能模式",
    qualityModeOffDesc: "在所有设备上流畅运行",
    qualityHintOn: "极光、动画和模糊已激活 — 如设备卡顿请禁用",
    qualityHintOff: "启用以激活极光、动画和背景模糊 — 旧设备可能卡顿",
    swatchPurple: "紫色",
    swatchAmber: "琥珀",
    swatchOcean: "海洋",
    swatchRose: "玫瑰",
    swatchForest: "森林",
    // ── 自定义驱动更改 ──────────────────────────────────────
    customDriverLabel: "自定义驱动更改",
    customDriverDesc: "对任意驱动进行欺骗或VKOnly处理",
    customDriverInfo: "对任意驱动文件应用自定义GPU欺骗或创建纯Vulkan驱动构建。",
    customDriverOpen: "打开自定义驱动工具",
    customDriverModalTitle: "自定义驱动工具",
    customDriverModalSub: "高级驱动修改",
    customDriverChooseFeature: "您想做什么？",
    customDriverChooseFeatureSub: "选择要对驱动文件执行的操作。",
    customDriverSpoofBtn: "🎭 自定义GPU欺骗",
    customDriverSpoofBtnDesc: "在任意libgsl.so中欺骗GPU型号",
    customDriverVKOnlyBtn: "⚡ 制作VKOnly",
    customDriverVKOnlyBtnDesc: "通过补丁仅保留驱动的Vulkan库，以与其他驱动配合使用",
    customDriverLibMode: "驱动是否同时包含lib和lib64？",
    customDriverLibModeSub: "选择驱动中存在的目录。",
    customDriverLibOnly: "仅lib",
    customDriverLib64Only: "仅lib64",
    customDriverBoth: "lib + lib64 都有",
    customDriverEnterPath: "输入驱动lib路径",
    customDriverEnterPathSub: "提供设备上驱动lib文件夹的完整路径。",
    customDriverLibPathLabel: "lib文件夹路径",
    customDriverLib64PathLabel: "lib64文件夹路径",
    customDriverPathPlaceholder: "例如 /sdcard/MyDriver/system/vendor/lib",
    customDriverPath64Placeholder: "例如 /sdcard/MyDriver/system/vendor/lib64",
    customDriverScanBtn: "🔍 扫描GPU型号",
    customDriverScanning: "正在扫描GPU型号...",
    customDriverScanResults: "已找到GPU型号",
    customDriverScanResultsSub: "选择一个或多个要欺骗的源型号",
    customDriverSelectSources: "选择源GPU型号：",
    customDriverTargetLabel: "将所有已选项 → 欺骗为目标GPU型号：",
    customDriverTargetPlaceholder: "例如 750",
    customDriverApplySpoof: "✅ 应用此欺骗",
    customDriverMoreSpoofs: "还要欺骗更多型号吗？",
    customDriverMoreSpoofsSub: "您可以将另一组源型号映射到不同的目标。",
    customDriverYesMore: "是，继续欺骗",
    customDriverNoDone: "否，已完成",
    customDriverSpoofComplete: "欺骗已应用！请刷入修改后的驱动以生效。",
    customDriverFlashToApply: "请将欺骗后的驱动刷入设备以使更改生效。不要仅重启 — 必须先刷入修改后的文件。",
    customDriverBackupInfo: "原始 libgsl.so 备份已保存到：",
    customDriverGSLMixWarning: "⚠️ 严重警告：请勿将此 libgsl.so 与其他驱动混用。只能与其来源驱动配套使用。与其他驱动搭配使用将导致系统无法启动（Bootloop）。",
    customDriverVendorWarning: "⚠️ 安全警告：请勿输入指向系统 /vendor/ 或 /system/ 分区的路径。切勿在实时环境中对 libgsl.so 进行欺骗操作，这将导致系统无法启动（Bootloop）。请始终对已复制到 /sdcard/ 的驱动文件进行操作。",
    customDriverVulkanHwNote: "提示：vulkan.adreno.so 可能位于 lib64/ 或 lib64/hw/ 目录中，工具会自动检测两个位置。",
    customDriverNoModels: "此文件中未找到Adreno型号。请确认您选择了正确的libgsl.so。",
    customDriverPathNotFound: "路径未找到，请重新检查并输入。",
    customDriverLibgslNotFound: "指定路径中未找到libgsl.so。",
    customDriverVKOnlyTitle: "选择驱动文件",
    customDriverVKOnlyInstructions: "从以下驱动目录选择5个必需文件：",
    customDriverVKOnlyFileList: "必需文件：",
    customDriverVKOnlyNote: "前4个文件将被重命名（lib→not）。5个文件内部引用均会被修补。",
    customDriverVKOnlySelectAll: "选择全部5个文件",
    customDriverVKOnlyProcess: "⚡ 应用VKOnly",
    customDriverVKOnlyOutput: "修改后的文件将保存到：",
    customDriverVKOnlyComplete: "VKOnly已应用！文件已保存到 /sdcard/Adreno_Driver/VKOnly/",
    customDriverVKOnlyFail: "VKOnly失败。请查看日志。",
    customDriverVKOnlyMissingFiles: "请选择全部5个必需文件。",
    customDriverCurrentTurn: "正在处理：",
    customDriverNextLib64: "继续处理lib64",
    wizardBack: "返回",
    wizardNext: "下一步",
    customDriverSpoofSafetyError: "源型号和目标型号的位数必须相同，以避免损坏ELF文件！"
};

const BUILTIN_ZH_TW = {
    title: "Adreno", 
    subtitle: "管理器",
    tabHome: "主頁", 
    tabConfig: "配置", 
    tabUtils: "工具", 
    tabData: "數據",
    statusReady: "就緒",
    welcomeTitle: "歡迎回來", 
    welcomeSubtitle: "精確管理您的GPU驅動程序設置",
    sysInfo: "系統概述", 
    sysInfoSub: "設備信息和狀態",
    device: "設備", 
    android: "安卓", 
    gpu: "GPU型號",
    driverVer: "驅動版本", 
    modVer: "模塊版本",
    hardwareTitle: "硬件詳情", 
    hardwareSub: "處理器和GPU信息",
    processorLabel: "處理器", 
    socLabel: "SoC", 
    cpuLabel: "CPU",
    socCodenameLabel: "SoC代號", 
    architectureLabel: "架構",
    gpuSectionLabel: "GPU", 
    gpuModelLabel: "GPU型號", 
    gpuVendorLabel: "供應商",
    rendererLabel: "渲染器", 
    driverVersionLabel: "驅動版本",
    langName: "語言", 
    langDesc: "選擇界面語言",
    langSystem: "系統",
    config: "驅動設置",
    configTitle: "驅動設置", 
    configSub: "模塊配置和選項",
    pltName: "PLT補丁",
    pltDesc: "當驅動程式中偵測到gpu++.so時自動啟用",
    pltSub: "若驅動程式中存在gpu++.so則自動啟用",
    qglName: "QGL配置",
    qglDesc: "為 Adreno GPU 設定 Qualcomm 圖形函式庫,建議改用 Lyb 核心管理器，以取得更精細的控制，並支援所有 SoC",
    qglSub: "提醒：最好使用 lyb Kernel Manager",
    edit: "編輯",
    armName: "ARM64優化",
    armDesc: "移除32位元庫，用於不支援32位元的ROM",
    verboseName: "詳細日誌",
    verboseDesc: "啟用詳細日誌以進行故障排除",
    renderName: "渲染模式",
    renderDesc: "默認渲染後端，性能均衡",
    renderDescSkiaVK: "Skia + Vulkan 後端 - 現代GPU性能更佳",
    renderDescSkiaGL: "Skia + OpenGL 後端 - 兼容性更好",
    renderDescSkiaVKAll: "激進SkiaVK模式，強制重啟應用 - 最高性能",
    renderNormal: "正常",
    renderStatusLabel: "即時渲染狀態",
    hwuiRendererLabel: "HWUI 渲染器",
    renderEngineLabel: "渲染引擎",
    useVulkanLabel: "Vulkan 屬性",
    renderStatusHint: "渲染器屬性已寫入 system.prop（持久化）並透過 resetprop 即時套用 — 重新啟動後完全生效",
    // Game Exclusion List
    gameExclTitle: "遊戲排除清單",
    gameExclSub: "⚠️ 僅在遊戲於 skiavk 或 skiavk_all 模式下崩潰時才新增 — 正常運行則請移除",
    gameExclDesc: "僅在遊戲於 skiavk 或 skiavk_all 模式下立即崩潰時（黑屏、即時強制關閉、GPU 故障）才新增至此清單。若遊戲在 skiavk 模式下運行正常，請勿新增 — 不必要地新增會使遊戲繼續使用舊版 GL 渲染器，並浪費守護程式保護槽位。若遊戲已不再崩潰，請將其移除。",
    gameExclBadge: "共享 · post-fs-data 和 service",
    gameExclAdd: "新增套件名稱",
    gameExclPlaceholder: "例如 com.example.game 或 com.example.*",
    gameExclAddBtn: "新增",
    gameExclRemove: "移除",
    gameExclEmpty: "排除清單為空",
    gameExclSave: "儲存清單",
    gameExclSaved: "遊戲排除清單已儲存",
    gameExclSaveError: "儲存排除清單失敗",
    gameExclReset: "恢復預設",
    gameExclResetConfirm: "將遊戲排除清單重置為出廠預設值？",
    gameExclCount: "個套件",
    gameExclWildcard: "支援萬用字元（例如 com.epicgames.*）",
    gameExclWhyTitle: "何時新增或移除遊戲",
    gameExclWhyBody: "僅在遊戲於 skiavk/skiavk_all 模式下崩潰時才新增：崩潰由雙 VkDevice 衝突引起 — 直接使用 Vulkan 的應用程式（自訂 Vulkan 引擎，如 UE4 等）與 HWUI 同時建立 VkDevice，自訂 Adreno 驅動程式無法處理 → SIGSEGV。相容守護程式會在偵測到應用程式後約 1 秒內將 HWUI 切換為 skiagl 解決衝突。若遊戲在 skiavk 模式下運行正常 — 請將其移除，無需保留在此清單中。",
    applyNowTitle: "立即套用渲染模式",
    applyNowDesc: "透過 resetprop 即時套用 — 無需重新啟動。重啟應用以查看效果。",
    applyNow: "立即套用",
    // Game Exclusion Daemon toggle
    daemonName: "遊戲排除守護程式",
    daemonDesc: "偵測到原生 Vulkan 遊戲時自動將 HWUI 切換為 skiagl。防止 skiavk 模式下的雙 VkDevice 崩潰。",
    daemonSub: "適用於在skiavk渲染模式下存在問題的應用",
    save: "保存並重啟",
    saveRebootInfo: "更改將在保存並重啟設備後生效。在進行更改之前，請務必備份當前配置。",
    resetDefaults: "恢復默認值",
    msgConfigSaved: "✓ 配置保存成功",
    utilsTitle: "工具和實用程序",
    utilsSub: "GPU工具和系統維護",
    gpuSpoofLabel: "GPU欺騙器", 
    gpuSpoofDesc: "修改GPU識別信息",
    spoofOriginalId: "原始ID",
    spoofTargetId: "目標ID",
    spoofSelectSource: "選擇來源",
    applyPatch: "應用補丁",
    fixesLabel: "快速修復",
    fixCamera: "相機",
    fixCam: "相機",
    fixRecorder: "屏幕錄制",
    fixRec: "屏幕錄制",
    fixNight: "夜間模式修復",
    maintenanceTitle: "系統維護",
    clearGPUCacheTitle: "清除GPU緩存", 
    clearGPUCacheDesc: "移除著色器和圖形緩存",
    clearGPUCache: "清除",
    trimStorageTitle: "整理存儲", 
    trimStorageDesc: "優化文件系統性能",
    trimStorage: "優化",
    clearCustomLangTitle: "清除自定義語言", 
    clearCustomLangDesc: "移除custom.json",
    clearCustomLang: "清除",
    msgSpoofApplied: "✓ GPU欺騙已應用",
    msgSpoofSuccess: "欺裝已應用! 需要重啟",
    msgSpoofFail: "欺裝失敗或輸入無效",
    msgFixApplied: "✓ 修復應用成功",
    msgTrimComplete: "✓ 存儲整理完成",
    fixCameraWarningTitle: "相機修復",
    fixCameraWarning: "這將刪除以下庫文件：\n\n• libCB.so\n• libgpudataproducer.so\n• libkcl.so\n• libkernelmanager.so\n• libllvm-qcom.so\n• libOpenCL.so\n• libOpenCL_adreno.so\n\n注意：這只能修復由這些模塊庫引起的問題。如果問題仍然存在，可能與模塊無關。\n\n要恢復這些庫文件，您需要重新刷入模塊。\n\n繼續？",
    fixRecorderWarningTitle: "屏幕錄製修復",
    fixRecorderWarning: "這將刪除以下庫文件：\n\n• libC2D2.so\n• libc2d30_bltlib.so\n• libc2dcolorconvert.so\n\n注意：這只能修復由這些模塊庫引起的問題。如果問題仍然存在，可能與模塊無關。\n\n要恢復這些庫文件，您需要重新刷入模塊。\n\n繼續？",
    fixNightWarningTitle: "夜間模式修復",
    fixNightWarning: "這將刪除以下庫文件：\n\n• libsnapdragon_color_manager.so\n\n注意：這只能修復由此模塊庫引起的問題。如果問題仍然存在，可能與模塊無關。\n\n要恢復此庫文件，您需要重新刷入模塊。\n\n繼續？",
    dataSection: "數據與日誌",
    dataTitle: "數據和日誌", 
    dataSub: "系統日誌和統計信息",
    statsTitle: "統計信息", 
    statsSub: "使用指標",
    statConfigs: "配置",
    statFixes: "修復",
    statSpoofs: "欺騙",
    configChanges: "配置", 
    fixesApplied: "修復", 
    spoofCount: "欺騙",
    logsTitle: "系統日誌", 
    logsSub: "實時活動監視器",
    logs: "系統日誌",
    clearLogs: "清除", 
    copyLogs: "復製",
    copy: "復製", 
    exportLogs: "導出",
    logsConnected: "已連接",
    logsLines: "行數：",
    autoBackupTitle: "自動備份信息",
    autoBackupSub: "配置持久化",
    autoBackupInfoTitle: "自動配置備份",
    autoBackupPath1: "您的所有設置會自動保存到：",
    autoBackupPath2: "/sdcard/Adreno_Driver/",
    autoBackupNote: "此文件夾直接連接到模塊，並在以下情況下保持不變：",
    autoBackupBullet1: "模塊更新",
    autoBackupBullet2: "模塊重新安裝",
    autoBackupBullet3: "系統重啟",
    autoBackupManualTitle: "手動配置管理",
    autoBackupManualDesc: "如果您想在重新安裝前重置或修改配置：",
    autoBackupStep1: "1. 導航到 /sdcard/Adreno_Driver/Config/",
    autoBackupStep2: "2. 刪除或修改 adreno_config.txt",
    autoBackupStep3: "3. 重新安裝模塊以獲得全新配置",
    aboutAppName: "Adreno管理器",
    aboutFeatures: "功能特性",
    feature1: "Banch++的PLT補丁",
    feature2: "QGL配置",
    feature3: "ARM64優化",
    feature4: "渲染選項（Vulkan/OpenGL）",
    feature5: "GPU緩存管理",
    feature6: "存儲優化",
    feature7: "自動備份系統",
    feature8: "硬件檢測",
    aboutCredit: "用❤️為Adreno社區創建",
    docTitle: "文檔", 
    docModalSub: "用戶指南和手冊",
    docTranslate: "翻譯",
    qglModalTitle: "QGL編輯器",
    qglModalSub: "高通圖形庫配置",
    qglSave: "保存",
    qglFormat: "格式化",
    qglReset: "重置",
    qglLines: "行數：",
    qglClose: "關閉",
    msgQGLSaved: "✅ QGL配置已保存（持久化）",
    msgQGLFail: "❌ QGL配置保存失敗",
    confirmCancel: "取消",
    confirmOk: "確認",
    connected: "已連接", 
    loading: "加載中...",
    restoreOriginal: "恢復原始",
    restoreOriginalDesc: "從備份恢復原廠libgsl.so",
    themePickerTitle: "🎨 選擇主題",
    themePickerSub: "自動保存到配置",
    displayStyleLabel: "顯示風格",
    colorModeGlass: "玻璃",
    colorModeGlassDesc: "毛玻璃模糊",
    colorModeBlur: "模糊",
    colorModeBlurDesc: "重度模糊",
    colorModeClear: "透明",
    colorModeClearDesc: "穿透效果",
    colorModeVivid: "鮮艷",
    colorModeVividDesc: "全彩效果",
    visualEffectsLabel: "視覺效果",
    qualityModeOn: "質量模式",
    qualityModeOnDesc: "所有效果已啟用",
    qualityModeOff: "性能模式",
    qualityModeOffDesc: "在所有設備上流暢運行",
    qualityHintOn: "極光、動畫和模糊已激活 — 如設備卡頓請禁用",
    qualityHintOff: "啟用以激活極光、動畫和背景模糊 — 舊設備可能卡頓",
    swatchPurple: "紫色",
    swatchAmber: "琥珀",
    swatchOcean: "海洋",
    swatchRose: "玫瑰",
    swatchForest: "森林",
    customDriverLabel: "自定義驅動更改",
    customDriverDesc: "對任意驅動進行欺騙或VKOnly處理",
    customDriverInfo: "對任意驅動文件應用自定義GPU欺騙或創建純Vulkan驅動構建。",
    customDriverOpen: "打開自定義驅動工具",
    customDriverModalTitle: "自定義驅動工具",
    customDriverModalSub: "進階驅動修改",
    customDriverChooseFeature: "您想做什麼？",
    customDriverChooseFeatureSub: "選擇要對驅動文件執行的操作。",
    customDriverSpoofBtn: "🎭 自定義GPU欺騙",
    customDriverSpoofBtnDesc: "在任意libgsl.so中欺騙GPU型號",
    customDriverVKOnlyBtn: "⚡ 製作VKOnly",
    customDriverVKOnlyBtnDesc: "透過修補僅保留驅動程式的Vulkan函式庫，以與其他驅動程式配合使用",
    customDriverLibMode: "驅動是否同時包含lib和lib64？",
    customDriverLibModeSub: "選擇驅動中存在的目錄。",
    customDriverLibOnly: "僅lib",
    customDriverLib64Only: "僅lib64",
    customDriverBoth: "lib + lib64 都有",
    customDriverEnterPath: "輸入驅動lib路徑",
    customDriverEnterPathSub: "提供設備上驅動lib文件夾的完整路徑。",
    customDriverLibPathLabel: "lib文件夾路徑",
    customDriverLib64PathLabel: "lib64文件夾路徑",
    customDriverPathPlaceholder: "例如 /sdcard/MyDriver/system/vendor/lib",
    customDriverPath64Placeholder: "例如 /sdcard/MyDriver/system/vendor/lib64",
    customDriverScanBtn: "🔍 掃描GPU型號",
    customDriverScanning: "正在掃描GPU型號...",
    customDriverScanResults: "已找到GPU型號",
    customDriverScanResultsSub: "選擇一個或多個要欺騙的源型號",
    customDriverSelectSources: "選擇源GPU型號：",
    customDriverTargetLabel: "將所有已選項 → 欺騙為目標GPU型號：",
    customDriverTargetPlaceholder: "例如 750",
    customDriverApplySpoof: "✅ 應用此欺騙",
    customDriverMoreSpoofs: "還要欺騙更多型號嗎？",
    customDriverMoreSpoofsSub: "您可以將另一組源型號映射到不同的目標。",
    customDriverYesMore: "是，繼續欺騙",
    customDriverNoDone: "否，已完成",
    customDriverSpoofComplete: "欺騙已應用！請刷入修改後的驅動以生效。",
    customDriverFlashToApply: "請將欺騙後的驅動刷入裝置以使更改生效。不要僅重啟 — 必須先刷入修改後的檔案。",
    customDriverBackupInfo: "原始 libgsl.so 備份已儲存至：",
    customDriverGSLMixWarning: "⚠️ 嚴重警告：請勿將此 libgsl.so 與其他驅動混用。只能與其來源驅動配套使用。與其他驅動搭配使用將導致系統無法開機（Bootloop）。",
    customDriverVendorWarning: "⚠️ 安全警告：請勿輸入指向系統 /vendor/ 或 /system/ 分割區的路徑。切勿在實時環境中對 libgsl.so 進行欺騙操作，這將導致系統無法開機（Bootloop）。請始終對已複製至 /sdcard/ 的驅動檔案進行操作。",
    customDriverVulkanHwNote: "提示：vulkan.adreno.so 可能位於 lib64/ 或 lib64/hw/ 目錄中，工具會自動偵測兩個位置。",
    customDriverNoModels: "此文件中未找到Adreno型號。請確認您選擇了正確的libgsl.so。",
    customDriverPathNotFound: "路徑未找到，請重新檢查並輸入。",
    customDriverLibgslNotFound: "指定路徑中未找到libgsl.so。",
    customDriverVKOnlyTitle: "選擇驅動文件",
    customDriverVKOnlyInstructions: "從以下驅動目錄選擇5個必需文件：",
    customDriverVKOnlyFileList: "必需文件：",
    customDriverVKOnlyNote: "前4個文件將被重命名（lib→not）。5個文件內部引用均會被修補。",
    customDriverVKOnlySelectAll: "選擇全部5個文件",
    customDriverVKOnlyProcess: "⚡ 應用VKOnly",
    customDriverVKOnlyOutput: "修改後的文件將保存到：",
    customDriverVKOnlyComplete: "VKOnly已應用！文件已保存到 /sdcard/Adreno_Driver/VKOnly/",
    customDriverVKOnlyFail: "VKOnly失敗。請查看日誌。",
    customDriverVKOnlyMissingFiles: "請選擇全部5個必需文件。",
    customDriverCurrentTurn: "正在處理：",
    customDriverNextLib64: "繼續處理lib64",
    wizardBack: "返回",
    wizardNext: "下一步",
    customDriverSpoofSafetyError: "源型號和目標型號的位數必須相同，以避免損壞ELF文件！"
};

// ============================================
// TRANSLATION SYSTEM
// ============================================

function applyTranslations(translations) {
    currentTranslations = { ...DEFAULT_EN, ...translations };
    
    // Batch all DOM text updates in a single rAF to prevent mid-frame layout thrash
    // that causes elements to briefly disappear during language switches
    requestAnimationFrame(() => {
        const elements = document.querySelectorAll('[data-i18n]');
        for (let i = 0; i < elements.length; i++) {
            const el = elements[i];
            const key = el.getAttribute('data-i18n');
            if (currentTranslations[key]) {
                if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                    el.placeholder = currentTranslations[key];
                } else {
                    el.textContent = currentTranslations[key];
                }
            }
        }
    });
}

async function loadCustomLanguage() {
    try {
        const res = await exec(`cat "${SD_LANG}/custom.json" 2>/dev/null`);
        if (res.errno === 0 && res.stdout && res.stdout.trim()) {
            const custom = JSON.parse(res.stdout);
            applyTranslations(custom);
            return true;
        }
    } catch (e) {
        console.error("Failed to load custom language:", e);
    }
    return false;
}

// Custom encodeURIComponent for shell safety
function customEncodeURIComponent(str) {
    return str.replace(/ /g, '%20')
              .replace(/"/g, '%22')
              .replace(/'/g, '%27')
              .replace(/\n/g, '%0A')
              .replace(/&/g, '%26')
              .replace(/\+/g, '%2B');
}

async function translateText(text, targetLang) {
    if (!text || text.length < 2) return text;
    const encodedText = customEncodeURIComponent(text);
    const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${targetLang}&dt=t&q=${encodedText}`;
    
    try {
        const res = await exec(`curl -s -A "Mozilla/5.0" "${url}"`);
        if (res.errno === 0 && res.stdout) {
            const raw = res.stdout;
            const match = raw.match(/^\[\[\["([^"]+)"/);
            if (match && match[1]) return match[1];
        }
    } catch (e) {
        console.error('Translation error:', e);
    }
    return text;
}

async function autoTranslateAndSave(targetLang) {
    setLoading(true);
    logToTerminal(`Auto-translating to ${targetLang}...`, 'info');
    
    try {
        const translated = { ...DEFAULT_EN };
        const keys = Object.keys(DEFAULT_EN);
        
        // Translate each key
        for (let i = 0; i < keys.length; i++) {
            const key = keys[i];
            if (i % 5 === 0) {
                logToTerminal(`Translating UI [${i}/${keys.length}]...`, 'info');
            }
            translated[key] = await translateText(DEFAULT_EN[key], targetLang);
        }
        
        // Save to custom.json
        const jsonContent = JSON.stringify(translated, null, 2);
        const escapedJson = jsonContent.replace(/'/g, "'\\''");
        
        await exec(`mkdir -p "${SD_LANG}" 2>/dev/null`);
        await exec(`echo '${escapedJson}' > "${SD_LANG}/custom.json"`);
        await exec(`cp "${SD_LANG}/custom.json" "${MOD_WEB_LANG}/custom.json" 2>/dev/null`);
        
        // Enable custom option
        const customOpt = document.getElementById('optCustom');
        if (customOpt) customOpt.disabled = false;
        
        logToTerminal('✓ UI Translation complete!', 'success');
        showToast('✅ Translation complete!');
        
        setLoading(false);
        return translated;
    } catch (e) {
        logToTerminal(`Translation error: ${e.message}`, 'error');
        setLoading(false);
        return null;
    }
}

async function performDocsTranslation() {
    let targetLang = currentLangCode;
    
    // If in custom mode, detect system language
    if (targetLang === 'en') {
        showToast('Already in English');
        return;
    }
    
    if (targetLang === 'custom' || targetLang === 'system') {
        const sysLangRes = await exec('getprop persist.sys.locale 2>/dev/null || getprop ro.product.locale 2>/dev/null');
        targetLang = sysLangRes.stdout.trim().split('-')[0] || 'en';
        if (targetLang === 'en') {
            showToast('System language is English');
            return;
        }
    }
    
    setLoading(true);
    logToTerminal(`Translating documentation to ${targetLang}...`, 'info');
    
    try {
        const readmeRes = await exec(`cat "${MOD_DOCS}/README.md" 2>/dev/null`);
        if (readmeRes.errno === 0 && readmeRes.stdout) {
            const lines = readmeRes.stdout.split('\n');
            let translatedLines = [];
            
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                
                // Skip code blocks and images
                if (line.length > 0 && !line.startsWith('```') && !line.startsWith('![')) {
                    const trans = await translateText(line, targetLang);
                    translatedLines.push(trans);
                } else {
                    translatedLines.push(lines[i]);
                }
                
                if (i % 10 === 0) {
                    logToTerminal(`Translating docs [${i}/${lines.length}]...`, 'info');
                }
            }
            
            const finalMd = translatedLines.join('\n').replace(/'/g, "'\\''");
            await exec(`mkdir -p "${SD_DOCS}" 2>/dev/null`);
            await exec(`echo '${finalMd}' > "${SD_DOCS}/custom_README.md"`);
            await exec(`cp "${SD_DOCS}/custom_README.md" "${MOD_DOCS}/custom_README.md" 2>/dev/null`);
            
            logToTerminal('✓ Documentation translated!', 'success');
            showToast('✅ Documentation translated!');
            
            // Reload the docs to show translated version
            openDocs();
        } else {
            showToast('⚠️ README.md not found');
            logToTerminal('README.md not found', 'error');
        }
    } catch (e) {
        logToTerminal(`Docs translation error: ${e.message}`, 'error');
        showToast('❌ Translation failed');
    } finally {
        setLoading(false);
    }
}

async function handleLanguageChange(e) {
    const value = e.target.value;
    currentLangCode = value;
    
    if (value === 'system') {
        // Get system language from Android properties
        let sysLangRes = await exec('getprop persist.sys.locale 2>/dev/null');
        if (!sysLangRes.stdout || !sysLangRes.stdout.trim()) {
            sysLangRes = await exec('getprop ro.product.locale 2>/dev/null');
        }
        
        const sysLangFull = sysLangRes.stdout.trim();
        const sysLang = sysLangFull.split('-')[0] || 'en';
        
        logToTerminal(`System language detected: ${sysLangFull}`, 'info');
        
        // Check for Chinese variants
        if (sysLang === 'zh') {
            if (sysLangFull.includes('CN') || sysLangFull.includes('SG')) {
                document.getElementById('LANG_SELECT').value = 'zh-CN';
                localStorage.setItem('adreno_lang', 'zh-CN');
                applyTranslations(BUILTIN_ZH_CN);
                currentLangCode = 'zh-CN';
                logToTerminal('Applied: Simplified Chinese', 'success');
            } else {
                document.getElementById('LANG_SELECT').value = 'zh-TW';
                localStorage.setItem('adreno_lang', 'zh-TW');
                applyTranslations(BUILTIN_ZH_TW);
                currentLangCode = 'zh-TW';
                logToTerminal('Applied: Traditional Chinese', 'success');
            }
            return;
        }
        
        // Check for English
        if (sysLang === 'en') {
            document.getElementById('LANG_SELECT').value = 'en';
            localStorage.setItem('adreno_lang', 'en');
            applyTranslations(DEFAULT_EN);
            currentLangCode = 'en';
            logToTerminal('Applied: English', 'success');
            return;
        }
        
        // System language not in built-in list
        logToTerminal(`Language ${sysLang} not built-in, checking for custom...`, 'info');
        
        // Check if custom already exists
        const customLoaded = await loadCustomLanguage();
        if (customLoaded) {
            logToTerminal('✓ Loaded existing custom translation', 'success');
            document.getElementById('LANG_SELECT').value = 'custom';
            localStorage.setItem('adreno_lang', 'custom');
        } else {
            // Ask user if they want to auto-translate
            const shouldCreate = await ConfirmDialog.show(
                'Create Custom Translation',
                `System language is '${sysLang}'.\n\nDo you want to generate a custom translation?`,
                '🌐'
            );
            
            if (shouldCreate) {
                const translated = await autoTranslateAndSave(sysLang);
                if (translated) {
                    applyTranslations(translated);
                    document.getElementById('LANG_SELECT').value = 'custom';
                    localStorage.setItem('adreno_lang', 'custom');
                    currentLangCode = 'custom';
                } else {
                    // Translation failed, fallback to English
                    applyTranslations(DEFAULT_EN);
                    document.getElementById('LANG_SELECT').value = 'en';
                    localStorage.setItem('adreno_lang', 'en');
                }
            } else {
                // User declined, use English
                applyTranslations(DEFAULT_EN);
                document.getElementById('LANG_SELECT').value = 'en';
                localStorage.setItem('adreno_lang', 'en');
                logToTerminal('Using English as fallback', 'info');
            }
        }
    } else if (value === 'custom') {
        const loaded = await loadCustomLanguage();
        if (!loaded) {
            showToast('⚠️ No custom translation found');
            logToTerminal('Custom translation not found', 'warn');
            // Fallback to English
            applyTranslations(DEFAULT_EN);
            const langSelect = document.getElementById('LANG_SELECT');
            if (langSelect) langSelect.value = 'en';
        } else {
            logToTerminal('✓ Custom translation loaded', 'success');
        }
    } else {
        const langMap = { 
            'en': DEFAULT_EN, 
            'zh-CN': BUILTIN_ZH_CN, 
            'zh-TW': BUILTIN_ZH_TW 
        };
        if (langMap[value]) {
            applyTranslations(langMap[value]);
            logToTerminal(`Applied: ${value}`, 'success');
        }
    }
    
    localStorage.setItem('adreno_lang', value);
}

// ============================================
// CORE FUNCTIONS
// ============================================

let loadingCount = 0;
function setLoading(state) {
    if (state) {
        loadingCount++;
        if (_spinner) _spinner.classList.add('active');
        if (_overlay) _overlay.style.display = 'block';
    } else {
        loadingCount = Math.max(0, loadingCount - 1);
        if (loadingCount === 0) {
            if (_spinner) _spinner.classList.remove('active');
            if (_overlay) _overlay.style.display = 'none';
        }
    }
}

function showToast(message) {
    const container = document.getElementById('toastContainer');
    if (!container) return;
    
    const toast = document.createElement('div');
    toast.className = 'toast';
    toast.textContent = message;
    container.appendChild(toast);
    
    setTimeout(() => toast.classList.add('show'), 10);
    setTimeout(() => {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
    }, 3000);
}

let _tabSwitching = false;
function switchTab(targetId) {
    const newTabId = targetId.startsWith('tab-') ? targetId : `tab-${targetId}`;
    const tabName = newTabId.replace('tab-', '');
    const currentSection = document.querySelector('.view-section.active');
    const newSection = document.getElementById(newTabId) || document.getElementById(targetId);
    if (!newSection || currentSection === newSection || _tabSwitching) return;
    _tabSwitching = true;

    // Batch DOM changes in rAF to avoid mid-frame layout thrash
    requestAnimationFrame(() => {
        if (currentSection) currentSection.classList.remove('active');
        newSection.classList.add('active');
        // Update nav item states using cached list
        const items = _navItems || document.querySelectorAll('.nav-item');
        for (let i = 0; i < items.length; i++) {
            const t = items[i].dataset.target || items[i].dataset.tab || '';
            items[i].classList.toggle('active', t === tabName || t === newTabId);
        }
    });

    setTimeout(() => { _tabSwitching = false; }, 220);
}

async function findModulePath() {
    const paths = [
        `/data/adb/modules/${MOD_ID}`,
        `/data/adb/modules_update/${MOD_ID}`,
        `/data/adb/magisk/${MOD_ID}`
    ];
    
    // Check all paths in parallel — faster than sequential exec calls
    const results = await Promise.all(
        paths.map(p => exec(`[ -d "${p}" ] && echo "exists"`))
    );
    
    for (let i = 0; i < paths.length; i++) {
        if (results[i].stdout && results[i].stdout.includes('exists')) return paths[i];
    }
    return "";
}

async function ensureDirectories() {
    await exec(`mkdir -p "${SD_ROOT}" "${SD_CONFIG}" "${SD_LANG}" "${SD_DOCS}" "${SD_ROOT}/Backup" "${SD_ROOT}/Statistics" 2>/dev/null`);
    await exec(`mkdir -p "${MOD_WEB_LANG}" 2>/dev/null`);
    
    // Create default language files only if they don't exist (to avoid slowdown on every load)
    const checkEn = await exec(`[ -f "${SD_LANG}/en.json" ] && echo "exists"`);
    if (!checkEn.stdout || !checkEn.stdout.includes('exists')) {
        const enStr = JSON.stringify(DEFAULT_EN, null, 2).replace(/'/g, "'\\''");
        await exec(`echo '${enStr}' > "${SD_LANG}/en.json" 2>/dev/null`);
        await exec(`echo '${enStr}' > "${MOD_WEB_LANG}/en.json" 2>/dev/null`);
        
        const twStr = JSON.stringify(BUILTIN_ZH_TW, null, 2).replace(/'/g, "'\\''");
        await exec(`echo '${twStr}' > "${SD_LANG}/zh-TW.json" 2>/dev/null`);
        await exec(`echo '${twStr}' > "${MOD_WEB_LANG}/zh-TW.json" 2>/dev/null`);
        
        const cnStr = JSON.stringify(BUILTIN_ZH_CN, null, 2).replace(/'/g, "'\\''");
        await exec(`echo '${cnStr}' > "${SD_LANG}/zh-CN.json" 2>/dev/null`);
        await exec(`echo '${cnStr}' > "${MOD_WEB_LANG}/zh-CN.json" 2>/dev/null`);
    }
}

// ============================================
// STATISTICS TRACKING
// ============================================

async function loadStatistics() {
    try {
        const res = await exec(`cat "${SD_STATS}" 2>/dev/null`);
        if (res.errno === 0 && res.stdout && res.stdout.trim()) {
            const loaded = JSON.parse(res.stdout);
            statistics = { ...statistics, ...loaded };
            updateStatisticsDisplay();
            logToTerminal('✓ Statistics loaded', 'info');
        }
    } catch (e) {
        logToTerminal('No previous statistics found, starting fresh', 'info');
    }
}

async function saveStatistics() {
    try {
        const json = JSON.stringify(statistics, null, 2);
        const escaped = json.replace(/'/g, "'\\''");
        await exec(`echo '${escaped}' > "${SD_STATS}"`);
    } catch (e) {
        console.error('Failed to save statistics:', e);
    }
}

function updateStatisticsDisplay() {
    if (_statConfig) _statConfig.textContent = statistics.configChanges;
    if (_statFixes)  _statFixes.textContent  = statistics.fixesApplied;
    if (_statSpoof)  _statSpoof.textContent  = statistics.spoofCount;
}

function incrementStat(statName) {
    if (statistics.hasOwnProperty(statName)) {
        statistics[statName]++;
        updateStatisticsDisplay();
        saveStatistics();
    }
}

// Terminal Logger
const terminalCache = { entries: [], maxLines: 100 };

function logToTerminal(message, type = 'info') {
    if (!_logArea) return;
    
    const now = new Date();
    const timestamp = `[${now.toLocaleTimeString()}]`;
    
    terminalCache.entries.push({ timestamp, message, type });
    if (terminalCache.entries.length > terminalCache.maxLines) {
        terminalCache.entries.shift();
    }
    
    const logLine = document.createElement('div');
    logLine.className = `log-line log-${type}`;
    const ts = document.createElement('span');
    ts.className = 'log-timestamp';
    ts.textContent = timestamp;
    const msg = document.createElement('span');
    msg.className = 'log-message';
    msg.textContent = message;
    logLine.appendChild(ts);
    logLine.appendChild(msg);
    
    _logArea.appendChild(logLine);
    _logArea.scrollTop = _logArea.scrollHeight;
    
    if (_logCount) _logCount.textContent = terminalCache.entries.length;
}

async function loadSystemInfo() {
    logToTerminal("Loading system info...", 'info');
    try {
        const [dev, ver, gpu, modVerRes, soc, socCodename, cpuInfo, arch, renderer, driverVer, hwuiProp, useVulkanProp] = await Promise.all([
            exec('getprop ro.product.model'),
            exec('getprop ro.build.version.release'),
            exec('cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo "Unknown"'),
            exec(`grep '^version=' "${MOD_PATH}/module.prop" 2>/dev/null | cut -d= -f2`),
            exec('getprop ro.board.platform'),
            exec('getprop ro.soc.model'),
            exec("cat /proc/cpuinfo | grep 'Hardware' | head -n1 | cut -d ':' -f2"),
            exec('getprop ro.product.cpu.abi'),
            exec("dumpsys SurfaceFlinger 2>/dev/null | grep 'GLES' | head -n1"),
            exec(`grep -ao "V@[0-9]*\\.[0-9]*" /vendor/lib64/egl/libGLESv2_adreno.so 2>/dev/null | head -n 1 | cut -c 3-`),
            exec('getprop debug.hwui.renderer 2>/dev/null'),
            exec('getprop ro.hwui.use_vulkan 2>/dev/null')
        ]);

        const hwuiPropVal      = (hwuiProp.stdout      || '').trim();
        const useVulkanPropVal = (useVulkanProp.stdout || '').trim();
        const updates = {
            'device': dev.stdout ? dev.stdout.trim() : 'Unknown',
            'android': ver.stdout ? ver.stdout.trim() : 'Unknown',
            'gpu': gpu.stdout ? gpu.stdout.trim() : 'Unknown',
            'modVer': modVerRes.stdout ? modVerRes.stdout.trim() : 'Unknown',
            'soc': soc.stdout ? soc.stdout.trim() : 'Unknown',
            'socCodename': socCodename.stdout ? socCodename.stdout.trim() : 'Unknown',
            'cpu': cpuInfo.stdout ? cpuInfo.stdout.trim() : (arch.stdout ? arch.stdout.trim() : 'Unknown'),
            'architecture': arch.stdout ? arch.stdout.trim() : 'Unknown',
            'gpuModel': renderer.stdout && renderer.stdout.match(/Adreno.*?(\d+)/) ? `Adreno ${renderer.stdout.match(/Adreno.*?(\d+)/)[1]}` : 'Unknown',
            'gpuVendor': "Qualcomm",
            'renderer': renderer.stdout ? renderer.stdout.split('\n')[0].trim() : 'Unknown',
            'driverVersion': driverVer.stdout ? driverVer.stdout.trim() : 'Unknown',
            'hwuiRendererStatus': hwuiPropVal      || '(system default)',
            'useVulkanStatus':    useVulkanPropVal || '(system default)',
            'renderEngineStatus': '(system default)'
        };

        Object.entries(updates).forEach(([id, value]) => {
            const el = document.getElementById(id);
            if (el) {
                el.textContent = value;
                el.classList.remove('skeleton-text');
            }
        });
        
        logToTerminal("✓ System info loaded", 'success');
    } catch (e) {
        logToTerminal(`Info load error: ${e.message}`, 'error');
    }
}

async function loadRenderStatus() {
    try {
        const [hwuiRes, reRes, vulkanPropRes] = await Promise.all([
            exec('getprop debug.hwui.renderer 2>/dev/null'),
            exec('getprop debug.renderengine.backend 2>/dev/null'),
            exec('getprop ro.hwui.use_vulkan 2>/dev/null')
        ]);

        const hwui       = (hwuiRes.stdout       || '').trim();
        const re         = (reRes.stdout         || '').trim();
        const useVulkan  = (vulkanPropRes.stdout  || '').trim();

        const hwuiDisplay      = hwui      || '(not set — system default)';
        const reDisplay        = re        || '(not set — system default)';
        const useVulkanDisplay = useVulkan || '(not set — system default)';

        const activeMode = hwui === 'skiavk' ? '🟢 SkiaVK active'
                         : hwui === 'skiagl' ? '🟡 SkiaGL active'
                         : hwui             ? `🔵 ${hwui}`
                         :                   '⚪ Normal (system default)';

        logToTerminal(`Render mode status: ${activeMode}`, hwui ? 'success' : 'info');
        logToTerminal(`  debug.hwui.renderer        = ${hwuiDisplay}`, 'info');
        logToTerminal(`  debug.renderengine.backend = ${reDisplay}`, 'info');
        logToTerminal(`  ro.hwui.use_vulkan          = ${useVulkanDisplay}`, 'info');
        logToTerminal('  (debug.hwui.renderer written to system.prop by service.sh for persistence. renderengine.backend set pre-SF via resetprop only — NOT in system.prop, avoids OEM watcher bootloop)', 'info');

        // Update DOM status elements if present in HTML
        const hwuiEl      = document.getElementById('hwuiRendererStatus');
        const reEl        = document.getElementById('renderEngineStatus');
        const vulkanEl    = document.getElementById('useVulkanStatus');
        if (hwuiEl)   hwuiEl.textContent   = hwuiDisplay;
        if (reEl)     reEl.textContent     = reDisplay;
        if (vulkanEl) vulkanEl.textContent = useVulkanDisplay;
    } catch (e) {
        logToTerminal('Could not read render props: ' + (e.message || e), 'warn');
    }
}

// ============================================================
// GAME EXCLUSION LIST — shared with post-fs-data.sh & service.sh
// File: /sdcard/Adreno_Driver/Config/game_exclusion_list.sh
// ============================================================

const GAME_EXCL_FILE = `${SD_CONFIG}/game_exclusion_list.sh`;
const GAME_EXCL_DATA = `/data/local/tmp/adreno_game_exclusion_list.sh`;
const GAME_EXCL_MOD  = () => `${MOD_PATH}/game_exclusion_list.sh`;

const DEFAULT_GAME_EXCL_PKGS = [
    'com.tencent.ig',
    'com.pubg.krmobile',
    'com.pubg.imobile',
    'com.vng.pubgmobile',
    'com.rekoo.pubgm',
    'com.tencent.tmgp.pubgmhd',
    'com.epicgames.*',
    'com.activision.callofduty.shooter',
    'com.garena.game.codm',
    'com.tencent.tmgp.cod',
    'com.vng.codmvn',
    'com.miHoYo.GenshinImpact',
    'com.cognosphere.GenshinImpact',
    'com.miHoYo.enterprise.HSRPrism',
    'com.HoYoverse.hkrpgoversea',
    'com.levelinfinite.hotta',
    'com.proximabeta.mfh',
    'com.HoYoverse.Nap',
    'com.miHoYo.ZZZ',
];

// Build the shell file content from a package array
function buildGameExclShell(pkgs) {
    const pkgLines = pkgs.map(p => `${p}`).join('\n');
    return `#!/system/bin/sh
# ============================================================
# ADRENO DRIVER MODULE — SHARED GAME EXCLUSION LIST
# ============================================================
# Sourced by post-fs-data.sh AND service.sh at boot.
# Edit via Adreno Manager → Config → Game Exclusion List.
# One package per line. Wildcards like com.example.* supported.
# ============================================================

GAME_EXCLUSION_PKGS="
${pkgLines}
"

_game_pkg_excluded() {
  local _p="$1" _e
  for _e in $GAME_EXCLUSION_PKGS; do
    case "$_p" in $_e) return 0;; esac
  done
  return 1
}
`;
}

// Parse package list from a shell file's GAME_EXCLUSION_PKGS="..." block
function parseGameExclShell(content) {
    if (!content) return null;
    const m = content.match(/GAME_EXCLUSION_PKGS="([^"]*)"/s);
    if (!m) return null;
    return m[1].split('\n')
        .map(l => l.trim())
        .filter(l => l && !l.startsWith('#'));
}

let _gameExclPkgs = [...DEFAULT_GAME_EXCL_PKGS];

async function loadGameExclusionList() {
    try {
        let content = '';
        const sdRes = await exec(`cat "${GAME_EXCL_FILE}" 2>/dev/null`);
        if (sdRes.stdout && sdRes.stdout.includes('GAME_EXCLUSION_PKGS')) {
            content = sdRes.stdout;
        } else {
            const dataRes = await exec(`cat "${GAME_EXCL_DATA}" 2>/dev/null`);
            if (dataRes.stdout && dataRes.stdout.includes('GAME_EXCLUSION_PKGS')) {
                content = dataRes.stdout;
            } else {
                const modRes = await exec(`cat "${GAME_EXCL_MOD()}" 2>/dev/null`);
                if (modRes.stdout && modRes.stdout.includes('GAME_EXCLUSION_PKGS')) {
                    content = modRes.stdout;
                }
            }
        }
        const parsed = content ? parseGameExclShell(content) : null;
        _gameExclPkgs = parsed && parsed.length > 0 ? parsed : [...DEFAULT_GAME_EXCL_PKGS];
    } catch (e) {
        _gameExclPkgs = [...DEFAULT_GAME_EXCL_PKGS];
    }
    renderGameExclUI();
}

async function saveGameExclusionList() {
    try {
        const shell = buildGameExclShell(_gameExclPkgs);
        // Escape single quotes for shell printf
        const escaped = shell.replace(/'/g, "'\\''");
        await exec(`mkdir -p "${SD_CONFIG}" 2>/dev/null`);
        await exec(`printf '%s' '${escaped}' > "${GAME_EXCL_FILE}" 2>/dev/null`);
        // Mirror to /data/local/tmp for early-boot access (post-fs-data reads this)
        await exec(`printf '%s' '${escaped}' > "${GAME_EXCL_DATA}" 2>/dev/null`);
        // Mirror to module path
        if (MOD_PATH) {
            await exec(`printf '%s' '${escaped}' > "${GAME_EXCL_MOD()}" 2>/dev/null`);
        }
        logToTerminal(`✅ Game exclusion list saved (${_gameExclPkgs.length} packages)`, 'success');
        showToast(currentTranslations.gameExclSaved || 'Game exclusion list saved');
    } catch (e) {
        logToTerminal(`❌ Failed to save game exclusion list: ${e}`, 'error');
        showToast(currentTranslations.gameExclSaveError || 'Failed to save exclusion list');
    }
}

function renderGameExclUI() {
    const t = currentTranslations;
    const listEl = document.getElementById('gameExclList');
    const countEl = document.getElementById('gameExclCount');
    if (!listEl) return;

    if (countEl) countEl.textContent = `${_gameExclPkgs.length} ${t.gameExclCount || 'packages'}`;

    if (_gameExclPkgs.length === 0) {
        listEl.innerHTML = `<div class="game-excl-empty">${t.gameExclEmpty || 'No packages in exclusion list'}</div>`;
        return;
    }

    listEl.innerHTML = _gameExclPkgs.map((pkg, i) => `
        <div class="game-excl-item slide-in" style="animation-delay:${i * 0.03}s">
            <div class="game-excl-pkg-col">
                <span class="game-excl-pkg">${pkg}</span>
                ${pkg.endsWith('.*') ? '<span class="game-excl-wild">wildcard</span>' : ''}
            </div>
            <button class="game-excl-remove ripple-effect" data-index="${i}" aria-label="Remove ${pkg}">
                <span>✕</span>
            </button>
        </div>
    `).join('');

    listEl.querySelectorAll('.game-excl-remove').forEach(btn => {
        btn.addEventListener('click', () => {
            const idx = parseInt(btn.dataset.index, 10);
            _gameExclPkgs.splice(idx, 1);
            renderGameExclUI();
        });
    });
}

function initGameExclSection() {
    const addBtn  = document.getElementById('btnGameExclAdd');
    const saveBtn = document.getElementById('btnGameExclSave');
    const resetBtn = document.getElementById('btnGameExclReset');
    const whyBtn  = document.getElementById('btnGameExclWhy');
    const whyBody = document.getElementById('gameExclWhyBody');

    if (addBtn) {
        addBtn.addEventListener('click', () => {
            const input = document.getElementById('gameExclInput');
            if (!input) return;
            const val = input.value.trim();
            if (!val) return;
            if (!/^[a-zA-Z0-9.*_\-]+$/.test(val)) {
                showToast('⚠️ Invalid package name format');
                return;
            }
            if (!_gameExclPkgs.includes(val)) {
                _gameExclPkgs.push(val);
                renderGameExclUI();
            }
            input.value = '';
        });
        // Enter key support
        document.getElementById('gameExclInput')?.addEventListener('keydown', e => {
            if (e.key === 'Enter') addBtn.click();
        });
    }

    if (saveBtn) saveBtn.addEventListener('click', saveGameExclusionList);

    if (resetBtn) {
        resetBtn.addEventListener('click', async () => {
            const confirmed = await ConfirmDialog.show(
                currentTranslations.gameExclReset || 'Reset to Defaults',
                currentTranslations.gameExclResetConfirm || 'Reset game exclusion list to factory defaults?',
                '♻️'
            );
            if (!confirmed) return;
            _gameExclPkgs = [...DEFAULT_GAME_EXCL_PKGS];
            renderGameExclUI();
        });
    }

    if (whyBtn && whyBody) {
        whyBtn.addEventListener('click', () => {
            const hidden = whyBody.style.display === 'none' || !whyBody.style.display;
            whyBody.style.display = hidden ? 'block' : 'none';
            whyBtn.classList.toggle('expanded', hidden);
        });
    }
}

// Show or hide the FORCE_SKIAVKTHREADED_BACKEND toggle row based on selected render mode.
// The force-threaded backend option is only relevant for skiavk / skiavk_all
// (those are the only modes that apply debug.renderengine.backend=skiavkthreaded).
function updateForceThreadedRowVisibility() {
    const mode = document.getElementById('RENDER_MODE')?.value || 'normal';
    const row  = document.getElementById('forceThreadedRow');
    if (row) {
        row.style.display = (mode === 'skiavk' || mode === 'skiavk_all') ? '' : 'none';
    }
}

async function loadConfig() {
    logToTerminal('Loading configuration...', 'info');
    const res = await exec(`cat "${SD_CONFIG}/adreno_config.txt" 2>/dev/null || cat "${MOD_PATH}/adreno_config.txt" 2>/dev/null`);
    
    if (res.errno !== 0 || !res.stdout) {
        logToTerminal('No config found, using defaults', 'warn');
        return;
    }
    
    const lines = res.stdout.split('\n');
    const config = {};
    lines.forEach(line => {
        const [key, val] = line.split('=');
        if (key && val) config[key.trim()] = val.trim();
    });
    
    const setToggle = (id, value) => {
        const el = document.getElementById(id);
        if (el) {
            el.checked = value === 'y';
            // Sync row highlight
            const row = el.closest('.setting-item');
            if (row) row.classList.toggle('is-on', el.checked);
        }
    };
    
    const setSelect = (id, value) => {
        const el = document.getElementById(id);
        if (el && value) el.value = value;
    };
    
    setToggle('PLT', config.PLT);
    setToggle('QGL', config.QGL);
    setToggle('ARM64_OPT', config.ARM64_OPT);
    setToggle('VERBOSE', config.VERBOSE);
    setToggle('GAME_EXCLUSION_DAEMON', config.GAME_EXCLUSION_DAEMON);
    setSelect('RENDER_MODE', config.RENDER_MODE);
    // Load FORCE_SKIAVKTHREADED_BACKEND toggle
    const _ftb = document.getElementById('FORCE_SKIAVKTHREADED_BACKEND');
    if (_ftb) _ftb.checked = config.FORCE_SKIAVKTHREADED_BACKEND === 'y';
    // Show/hide forceThreadedRow based on loaded mode
    updateForceThreadedRowVisibility();
    
    // Load theme (no reboot needed — UI only)
    if (config.THEME) {
        applyTheme(config.THEME);
    }
    
    logToTerminal('✓ Configuration loaded', 'success');
    
    // Show current live render prop values so user can verify what's actually active
    await loadRenderStatus();
}

// Apply current render mode props RIGHT NOW via resetprop — no reboot needed.
async function applyRenderNow() {
    const renderMode = document.getElementById('RENDER_MODE')?.value || 'normal';
    setLoading(true);
    logToTerminal(`Applying render mode NOW: ${renderMode}`, 'info');

    try {
        const rpCheck = await exec('command -v resetprop 2>/dev/null && echo yes || echo no');
        if (!rpCheck.stdout || !rpCheck.stdout.includes('yes')) {
            showToast('❌ resetprop not available on this device');
            logToTerminal('❌ resetprop not found — cannot apply without reboot', 'error');
            setLoading(false);
            return;
        }

        // ── Step 1: Set props live via resetprop ─────────────────────────────
        const _ALL_SKIAVK_PROPS = [
            ['debug.hwui.renderer',                      'skiavk'],
            // debug.renderengine.backend intentionally NOT in live apply list.
            // SF is running — OEM ROM change callbacks fire RenderEngine reinit
            // mid-frame → SF crash → all apps lose surfaces → watchdog reboot.
            // Backend is written to system.prop (persists on next boot) and set
            // via resetprop BEFORE SF starts in post-fs-data.sh only.
            // ── DANGEROUS SF PROPS INTENTIONALLY OMITTED ─────────────────────────
            // debug.sf.latch_unsignaled, debug.sf.auto_latch_unsignaled,
            // debug.sf.disable_backpressure, debug.sf.enable_hwc_vds,
            // ro.sf.disable_triple_buffer, debug.sf.client_composition_cache_size,
            // debug.sf.enable_transaction_tracing, ro.surface_flinger.use_context_priority,
            // ro.surface_flinger.max_frame_buffer_acquired_buffers,
            // ro.surface_flinger.force_hwc_copy_for_virtual_displays,
            // debug.sf.use_phase_offsets_as_durations
            //
            // ROOT CAUSE of "shows for a second then whole screen black":
            // latch_unsignaled tells SF to present frames BEFORE GPU fence signals.
            // On custom Adreno drivers with broken fence FD export, the fence NEVER
            // signals → SF presents frame 1 (user sees app ~1s) → ALL buffers stall
            // waiting for unsignaled fences → HWUI deadlock → black screen.
            // disable_backpressure removes SF's only safety valve. disable_triple_buffer
            // and max_frame_buffer=2 starve the pipeline of render buffers, same outcome.
            // use_phase_offsets_as_durations is Samsung HWC-specific; on MIUI/ColorOS/
            // other OEM ROMs it misinterprets vsync offsets → wrong frame scheduling.
            // These props remain in _CLEAR_ALL so they get cleaned up on mode switches
            // from older module versions that may have set them.
            // Qualcomm flags
            ['com.qc.hardware',                          'true'],
            ['persist.sys.force_sw_gles',                '0'],
            // HWUI Skia Vulkan stability
            ['debug.hwui.use_buffer_age',                'false'],
            ['debug.hwui.use_partial_updates',           'false'],
            ['debug.hwui.use_gpu_pixel_buffers',         'false'],
            ['renderthread.skia.reduceopstasksplitting', 'false'],
            ['debug.hwui.skip_empty_damage',             'true'],
            ['debug.hwui.webview_overlays_enabled',      'true'],
            ['debug.hwui.skia_tracing_enabled',          'false'],
            ['debug.hwui.skia_use_perfetto_track_events','false'],
            ['debug.hwui.capture_skp_enabled',           'false'],
            ['debug.hwui.skia_atrace_enabled',           'false'],
            ['debug.hwui.use_hint_manager',              'true'],
            ['debug.hwui.target_cpu_time_percent',       '33'],  // 33% CPU / 67% GPU — correct for Vulkan async cmd buffer thread; 50% starves GPU fence waits
            // OEM/legacy ROM compat
            ['debug.vulkan.layers',                      ''],    // clear OEM Vulkan layers (crash on custom driver ABI)
            ['ro.hwui.use_vulkan',                       'true'],// MIUI/HyperOS gate for skiavk renderer path
            ['debug.hwui.recycled_buffer_cache_size',    '4'],   // AOSP default. 2 causes constant VkBuffer realloc → OOM spikes
            ['debug.hwui.overdraw',                      'false'],
            ['debug.hwui.profile',                       'false'],// VkQueryPool profiling crashes on custom Adreno firmware
            ['debug.hwui.show_dirty_regions',            'false'],
            ['graphics.gpu.profiler.support',            'false'],// Snapdragon Profiler intercept layer = wrong ABI on custom drivers
            // EGL shader blob cache
            ['ro.egl.blobcache.multifile',               'true'],     // per-process files, no concurrent write corruption
            ['ro.egl.blobcache.multifile_limit',         '33554432'], // 32MB cap per file
            // HWUI debug overhead elimination (confirmed AOSP Properties.h/cpp/ThreadedRenderer.java)
            ['debug.hwui.render_thread',                 'true'],// ensure async threaded rendering
            ['debug.hwui.render_dirty_regions',          'false'],// disable HWUI partial invalidates (pairs with use_partial_updates)
            ['debug.hwui.show_layers_updates',           'false'],// PROPERTY_DEBUG_LAYERS_UPDATES
            ['debug.hwui.filter_test_overhead',          'false'],// PROPERTY_FILTER_TEST_OVERHEAD
            ['debug.hwui.nv_profiling',                  'false'],// PROPERTY_DEBUG_NV_PROFILING (NVidia PerfHUD, no-op on Adreno)
            ['debug.hwui.8bit_hdr_headroom',             'false'],// PROPERTY_8BIT_HDR_HEADROOM
            ['debug.hwui.skip_eglmanager_telemetry',     'true'], // PROPERTY_SKIP_EGLMANAGER_TELEMETRY (skip init overhead)
            // initialize_gl_always=false — do NOT pre-load GL at Zygote when Vulkan active.
            // true loads both drivers simultaneously → ~20MB extra RAM per process → OOM on heavy apps.
            ['debug.hwui.initialize_gl_always',          'false'],
            ['debug.hwui.level',                         '0'],   // kDebugDisabled — no cache/memory debug
            ['debug.hwui.disable_vsync',                 'false'],// EXPLICIT SAFETY: neutralize OEM build.props with disable_vsync=true
            // System performance
            ['persist.device_config.runtime_native.usap_pool_enabled', 'true'], // USAP pre-fork pool → faster app cold-start
            ['debug.gralloc.enable_fb_ubwc',             '1'],   // UBWC framebuffer compression (Adreno: -30-50% bandwidth)
            ['persist.sys.perf.topAppRenderThreadBoost.enable', 'true'], // QTI PerfLock: boost foreground render thread
            ['persist.sys.gpu.working_thread_priority',  '1'],   // elevate GPU driver kernel thread priority
            // ── SF phase offsets INTENTIONALLY OMITTED ───────────────────────────────────
            // debug.sf.early_phase_offset_ns / early_app_phase_offset_ns / early_gl_phase_offset_ns /
            // early_gl_app_phase_offset_ns were SM8150 (OnePlus 7/7T) device-tree workarounds
            // (AOSP bug:75985430). At 120Hz, vsync period is 8.3ms; a 500µs early-SF phase is too
            // tight for custom Adreno driver fence latency on Adreno 6xx/7xx SoCs → SF misses vsync
            // every frame → frame-drop cascade → Android watchdog reboot loop.
            // Device trees provide correctly-tuned values; overriding them here causes regressions.
            // These remain in _CLEAR_ALL so old values from previous module versions are cleaned up.
            // (debug.sf.use_phase_offsets_as_durations — also EXCLUDED: Samsung HWC-specific only)
            // Disable Android 15+ experimental Graphite Skia backend — conflicts with custom drivers
            ['debug.hwui.use_skia_graphite',             'false'],
            // blur: NOT disabled — blanket disable breaks Samsung One UI / MIUI WindowBlurBehind.
            // Only disable on specific devices with confirmed Vulkan blur compute crashes.
            ['ro.sf.blurs_are_expensive',                '1'],   // hint to apps to reduce blur requests
            // vendor.gralloc.enable_fb_ubwc=1 — CAF gralloc4 namespace for Android 12+
            ['vendor.gralloc.enable_fb_ubwc',            '1'],
            // Samsung One UI: explicit Vulkan enable gate.
            ['ro.config.vulkan.enabled',                 'true'],
            // MIUI/HyperOS: internal vendor Vulkan gate (separate from ro.hwui.use_vulkan)
            ['persist.vendor.vulkan.enable',             '1'],
            // disable_pre_rotation: NOT SET. UE4/Unity query VkSurfaceCapabilitiesKHR::currentTransform
            // and handle pre-rotation in projection matrix. Setting true → IDENTITY transform reported
            // but display physically rotated → swapchain dimension mismatch → VK_ERROR_OUT_OF_DATE_KHR
            // loop → crash on launch (PUBG Mobile, CoD Mobile, Fortnite, Unity games).
            ['debug.hwui.force_dark',                    'false'],
            // ── Text atlas: AOSP defaults restored ───────────────────────────────────────
            // Reduction to 512×256/1024×512 caused glyph cache overflow → font corruption → HWUI crash
            // Modern Adreno 6xx/7xx Vulkan heaps handle full-size atlases without OOM.
            ['ro.hwui.text_small_cache_width',              '1024'],
            ['ro.hwui.text_small_cache_height',             '512'],
            ['ro.hwui.text_large_cache_width',              '2048'],
            ['ro.hwui.text_large_cache_height',             '1024'],
            // Shadow/gradient cache reduction: reduce peak VRAM budget
            ['ro.hwui.drop_shadow_cache_size',        '3'],
            ['ro.hwui.gradient_cache_size',           '1'],
            // native_mode: NOT SET. Forces sRGB globally → disables HDR/WCG on capable displays.
            // HDR output should be determined by display capabilities, not forced off.
            // Samsung/Xiaomi WCG fix: maps BT.601/170M → VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
            ['debug.sf.treat_170m_as_sRGB',              '1'],
            // Clear OEM EGL debug hook — MIUI/HyperOS/ColorOS inject hooks with wrong ABI
            // causing SIGSEGV in libvulkan on every app open (ANativeWindow pointer corruption)
            ['debug.egl.debug_proc',                     ''],
            // ── Always-active HW path reinforcement ──────────────────────────────────────────
            // These mirror system.prop entries but must also be resetprop'd because many OEM ROMs
            // (MIUI, HyperOS, FuntouchOS, ColorOS) run vendor init scripts AFTER boot_completed
            // that override these props back to their OEM defaults. resetprop at service.sh time
            // re-enforces them after OEM init completes.
            //
            // SF HW compositing — forces hardware composer path.
            // OEM ROMs with skiavk enabled may try to set debug.sf.hw=0 via init scripts when
            // they detect custom driver, falling back to SW composition which crashes custom
            // Adreno UBWC framebuffers (wrong buffer format).
            ['debug.sf.hw',                              '1'],
            // OEM UI hardware acceleration gate — OPPO/ColorOS, RealmeUI, FuntouchOS check this
            // at runtime in addition to at boot. Without it some OEM init scripts reset the UI
            // to software paths, causing a second crash wave when the user opens an app.
            ['persist.sys.ui.hw',                        '1'],
            // EGL hardware path — OEM HyperOS/MIUI vendor init may reset debug.egl.hw to 0
            // after detecting a non-stock driver. With skiavk, EGL HW path is required for
            // ANativeWindow acquisition before VkSurfaceKHR is created.
            ['debug.egl.hw',                             '1'],
            // EGL profiler + trace disable — prevents OEM hook reattachment. Some MIUI/HyperOS
            // builds re-enable these in a late_start service after boot_completed.
            ['debug.egl.profiler',                       '0'],
            ['debug.egl.trace',                          '0'],
            // ── OEM Vulkan layer clearing ─────────────────────────────────────────────────────
            // debug.vulkan.dev.layers — vendor namespace, SEPARATE from debug.vulkan.layers.
            // MIUI HyperOS 2.0+, OPPO ColorOS 14+, and Samsung One UI 6+ inject vendor
            // validation/trace layers via this prop. These layers have wrong ABI for custom
            // Adreno drivers → vkCreateDevice fails with VK_ERROR_LAYER_NOT_PRESENT → every
            // app crashes at Vulkan device initialization (before any frame is drawn).
            ['debug.vulkan.dev.layers',                  ''],
            // persist.graphics.vulkan.validation_enable — OEM Vulkan validation gate.
            // Some OEM ROMs (HyperOS 2+, ColorOS 14+) enable Vulkan validation layers by default
            // to collect telemetry. Validation layers have wrong function table ABI on custom
            // Adreno drivers → intercept every Vulkan call with wrong struct offsets → SIGSEGV.
            ['persist.graphics.vulkan.validation_enable','0'],
            // ── HWUI drawing state enforcement ───────────────────────────────────────────────
            // debug.hwui.drawing_enabled — HWUI global drawing gate.
            // Vivo FuntouchOS and some OPPO ColorOS variants set this to "false" in vendor props
            // to disable hardware rendering for certain "sensitive" app categories (banking, etc.).
            // With skiavk, a disabled drawing state causes HWUI to initialize the Vulkan backend
            // then immediately tear it down → dangling VkDevice reference → crash on next draw.
            ['debug.hwui.drawing_enabled',               'true'],
            // hwui.disable_vsync — OEM-specific (no debug prefix) vsync disable prop.
            // Different from debug.hwui.disable_vsync. Set by some Qualcomm vendor init.rc
            // scripts on legacy devices (Adreno 5xx era) to work around tearing. When active
            // with skiavk, disables the VSync fence that Vulkan swapchain presentation waits
            // on → swapchain image presented before GPU finishes → memory corruption → crash.
            ['hwui.disable_vsync',                       'false'],
            // ── HWUI render caches — significantly reduce texture upload stalls ───────
            // These are stripped by _CLEAR_ALL every boot but never re-set → system uses
            // outdated defaults (texture_cache=24MB, layer=16MB, path=4MB) that cause
            // repeated re-uploads and stutter on mid/high-end Adreno 6xx/7xx devices.
            // Values: 2-3× AOSP defaults, safe for devices with 3GB+ RAM.
            ['debug.hwui.texture_cache_size',            '72'],  // 72MB (default 24MB) — fewer texture re-uploads → less stutter
            ['debug.hwui.layer_cache_size',              '48'],  // 48MB (default 16MB) — more offscreen layer reuse → smoother transitions
            ['debug.hwui.path_cache_size',               '32'],  // 32MB (default  4MB) — better path rasterization reuse → smoother complex UIs
        ];
        const _CLEAR_ALL = [
            'debug.hwui.renderer', 'debug.renderengine.backend',
            'debug.sf.latch_unsignaled', 'debug.sf.auto_latch_unsignaled',
            'debug.sf.disable_backpressure', 'debug.sf.enable_hwc_vds',
            'ro.sf.disable_triple_buffer', 'debug.sf.client_composition_cache_size',
            'debug.sf.enable_transaction_tracing',
            'ro.surface_flinger.use_context_priority',
            'ro.surface_flinger.max_frame_buffer_acquired_buffers',
            'ro.surface_flinger.force_hwc_copy_for_virtual_displays',
            'com.qc.hardware', 'persist.sys.force_sw_gles',
            'debug.hwui.use_buffer_age', 'debug.hwui.use_partial_updates',
            'debug.hwui.use_gpu_pixel_buffers', 'renderthread.skia.reduceopstasksplitting',
            'debug.hwui.skip_empty_damage', 'debug.hwui.webview_overlays_enabled',
            'debug.hwui.skia_tracing_enabled', 'debug.hwui.skia_use_perfetto_track_events',
            'debug.hwui.capture_skp_enabled', 'debug.hwui.skia_atrace_enabled',
            'debug.hwui.use_hint_manager', 'debug.hwui.target_cpu_time_percent',
            'debug.vulkan.layers', 'ro.hwui.use_vulkan',
            'debug.hwui.recycled_buffer_cache_size',
            'debug.hwui.overdraw', 'debug.hwui.profile',
            'debug.hwui.show_dirty_regions', 'graphics.gpu.profiler.support',
            'ro.egl.blobcache.multifile', 'ro.egl.blobcache.multifile_limit',
            'debug.hwui.render_thread', 'debug.hwui.render_dirty_regions', 'debug.hwui.show_layers_updates',
            'debug.hwui.filter_test_overhead', 'debug.hwui.nv_profiling',
            'debug.hwui.clip_surfaceviews', 'debug.hwui.8bit_hdr_headroom',
            'debug.hwui.skip_eglmanager_telemetry', 'debug.hwui.initialize_gl_always',
            'debug.hwui.level', 'debug.hwui.disable_vsync',
            'persist.device_config.runtime_native.usap_pool_enabled',
            'debug.gralloc.enable_fb_ubwc', 'vendor.gralloc.enable_fb_ubwc',
            'persist.sys.perf.topAppRenderThreadBoost.enable',
            'persist.sys.gpu.working_thread_priority',
            // legacy device compatibility
            'debug.sf.early_phase_offset_ns', 'debug.sf.early_app_phase_offset_ns',
            'debug.sf.early_gl_phase_offset_ns', 'debug.sf.early_gl_app_phase_offset_ns',
            'debug.hwui.use_skia_graphite', 'ro.surface_flinger.supports_background_blur',
            'persist.sys.sf.disable_blurs', 'ro.sf.blurs_are_expensive',
            // dangerous OEM props — always strip, never write
            'hwui.disable_vsync', 'debug.vulkan.layers.enable',
            // legacy props — no longer written but must be cleared if present from older module versions
            'debug.hwui.texture_cache_size', 'debug.hwui.layer_cache_size',
            'debug.hwui.path_cache_size', 'debug.sf.use_phase_offsets_as_durations',
            // new props added to _ALL_SKIAVK_PROPS must also be in _CLEAR_ALL
            // so normal/skiagl mode correctly deletes them via resetprop --delete
            'ro.config.vulkan.enabled', 'persist.vendor.vulkan.enable',
            'persist.graphics.vulkan.disable_pre_rotation',
            'debug.hwui.force_dark', 'debug.sf.treat_170m_as_sRGB',
            // ── Critical SkiaVK crash-fix props — must be cleared on mode switch ──────
            'ro.hwui.text_small_cache_width', 'ro.hwui.text_small_cache_height',
            'ro.hwui.text_large_cache_width', 'ro.hwui.text_large_cache_height',
            'ro.hwui.drop_shadow_cache_size', 'ro.hwui.gradient_cache_size',
            'persist.sys.sf.native_mode', 'debug.egl.debug_proc',
            // new OEM/crash-fix props — must also clear on mode switch
            'debug.sf.hw', 'persist.sys.ui.hw', 'debug.egl.hw',
            'debug.egl.profiler', 'debug.egl.trace',
            'debug.vulkan.dev.layers', 'persist.graphics.vulkan.validation_enable',
            'debug.hwui.drawing_enabled',
            // NOTE: 'hwui.disable_vsync' and 'debug.hwui.force_dark' already appear above —
            // duplicates removed to prevent ambiguity in resetprop --delete loops.
        ];

        // ── Props that are safe in system.prop but MUST NOT be resetprop'd live ──────
        // These props have OEM property watchers or SF-level callbacks that fire when
        // the value changes at runtime. Setting them live causes systemic crashes:
        //
        //   debug.renderengine.backend — SF render engine prop. On MIUI/HyperOS, Samsung
        //   OneUI, and ColorOS, SurfaceFlinger registers SystemProperties::addChangeCallback
        //   for this. When it fires live, SF attempts a render engine reinitialization on the
        //   custom Adreno driver mid-frame → SF crash → ALL apps lose their window surfaces
        //   → "all apps crash immediately" with no recovery until reboot.
        //
        //   ro.hwui.use_vulkan — MIUI/HyperOS HWUIApplicationState has a live SystemProperties
        //   watcher for this prop. When changed 0→1 while device is running, it triggers
        //   simultaneous Vulkan initialization across ALL running HWUI processes. Custom Adreno
        //   drivers cannot handle concurrent VkDevice creation in dozens of processes at once
        //   → SIGSEGV cascade → every single running app crashes.
        //
        //   ro.config.vulkan.enabled — Samsung Vulkan gate. Samsung framework has a live
        //   callback; change triggers renderer reinit in running apps.
        //
        //   persist.vendor.vulkan.enable — OEM Vulkan gate. Vendor init service reacts to
        //   live changes by re-evaluating Vulkan availability → reinit cascade.
        //
        // FIX: These props are STILL written to system.prop (Step 2), so they take effect
        // on next boot. They are just never applied via live resetprop.
        const _LIVE_UNSAFE_PROPS = new Set([
            'debug.renderengine.backend',   // SF render engine — OEM ROM change callback → SF crash
            'ro.hwui.use_vulkan',            // MIUI/HyperOS live watcher → HWUI reinit cascade
            'ro.config.vulkan.enabled',      // Samsung Vulkan gate — live callback in framework
            'persist.vendor.vulkan.enable',  // OEM Vulkan gate — vendor init service reacts live
        ]);

        if (renderMode === 'skiavk' || renderMode === 'skiavk_all') {
            // Apply skiavk props live via resetprop, EXCLUDING _LIVE_UNSAFE_PROPS.
            // Unsafe props (SF backend, OEM Vulkan gates) are written to system.prop only
            // and take effect on next boot — setting them live causes systemic app crashes
            // on OEM ROMs that have runtime property watchers for these props.
            // skiavk_all additionally throttled-force-stops background apps (150ms gap)
            // so every process cold-starts fresh with skiavk — no mixed renderer state.
            for (const [prop, val] of _ALL_SKIAVK_PROPS) {
                if (_LIVE_UNSAFE_PROPS.has(prop)) continue; // system.prop only — see comment above
                await exec(`resetprop ${prop} "${val}"`);
            }
            logToTerminal('✅ debug.hwui.renderer = skiavk', 'success');
            logToTerminal('ℹ️  debug.renderengine.backend = skiavkthreaded → system.prop only (NOT live-resetprop — OEM ROM SF property watcher causes SF crash + all apps lose surfaces if set live)', 'warn');
            logToTerminal('✅ Qualcomm flags + HWUI Skia Vulkan stability + CPU scheduling (16 props)', 'success');
            logToTerminal('✅ OEM compat: Vulkan layers cleared, MIUI gate, buffer cache, profilers (7 props)', 'success');
            logToTerminal('✅ EGL blob cache: multifile + 32MB limit (2 props)', 'success');
            logToTerminal('✅ HWUI debug overhead elimination + vsync safety (16 props)', 'success');
            logToTerminal('✅ System perf: USAP pool, UBWC, QTI PerfLock, GPU thread priority (4 props)', 'success');
            logToTerminal('✅ SF phase offsets NOT SET (omitted — SM8150-specific values cause vsync starvation on Adreno 6xx/7xx at 90/120Hz)', 'info');
            logToTerminal('✅ Graphite disable + blur hint + VK crash fixes (11 props)', 'success');
            logToTerminal('⚠️  SF fence/buffer props (latch_unsignaled, disable_backpressure, disable_triple_buffer) NOT SET — caused "1s then black" crash on custom Adreno drivers', 'warn');
            logToTerminal(`✅ ${_ALL_SKIAVK_PROPS.length} props total applied live`, 'success');
        } else if (renderMode === 'skiagl') {
            // Apply SkiaGL props via resetprop — full set synced with post-fs-data.sh
            const _SKIAGL_PROPS = [
                ['debug.hwui.renderer',                           'skiagl'],
                // debug.renderengine.backend intentionally NOT here — SF is running,
                // OEM ROM change callbacks fire → SF crash (same as skiavk).
                // Backend is written to system.prop and set pre-SF via post-fs-data.sh.
                // OEM/hardware gate
                ['persist.sys.force_sw_gles',                    '0'],
                ['com.qc.hardware',                               'true'],
                // GL partial-update props: set to false — EGL_EXT_buffer_age and
                // EGL_KHR_partial_update are unreliable on custom Adreno drivers.
                // Incorrect buffer age / dirty-rect values cause stale pixels (old frame
                // content bleeding through partial-update regions). Full-frame rendering
                // is safer and avoids visual glitches in all apps.
                ['debug.hwui.use_buffer_age',                    'false'],
                ['debug.hwui.use_partial_updates',               'false'],
                ['debug.hwui.render_dirty_regions',              'false'],
                ['debug.hwui.webview_overlays_enabled',          'true'],
                // reduceopstasksplitting=false — AOSP default. true causes rendering
                // artifacts (incorrect z-ordering, missing UI elements) in apps with
                // complex Canvas/Skia draw operations. Leave at safe default.
                ['renderthread.skia.reduceopstasksplitting',     'false'],
                // Disable Skia tracing/profiling overhead
                ['debug.hwui.skia_tracing_enabled',              'false'],
                ['debug.hwui.skia_use_perfetto_track_events',    'false'],
                ['debug.hwui.capture_skp_enabled',               'false'],
                ['debug.hwui.skia_atrace_enabled',               'false'],
                // Disable debug overlays
                ['debug.hwui.overdraw',                          'false'],
                ['debug.hwui.profile',                           'false'],
                ['debug.hwui.show_dirty_regions',                'false'],
                ['debug.hwui.show_layers_updates',               'false'],
                // EGL shader blob cache
                ['ro.egl.blobcache.multifile',                   'true'],
                ['ro.egl.blobcache.multifile_limit',             '33554432'],
                // HWUI frame scheduling
                ['debug.hwui.render_thread',                     'true'],
                ['debug.hwui.use_hint_manager',                  'true'],
                ['debug.hwui.target_cpu_time_percent',           '66'],
                ['debug.hwui.skip_eglmanager_telemetry',         'true'],
                // initialize_gl_always=false — CRASH FIX: ro.zygote.disable_gl_preload=true
                // prevents Zygote from preloading the stock GL driver. If initialize_gl_always=true,
                // HWUI forces EGL init in EVERY process at startup. NDK/game apps that also init
                // their own Vulkan context from a different thread hit a race between HWUI's EGL
                // init (RenderThread) and the game engine's Vulkan init → SIGSEGV in libEGL/libvulkan.
                // false = lazy GL init when HWUI actually needs it — no race, no crash.
                ['debug.hwui.initialize_gl_always',              'false'],
                ['debug.hwui.disable_vsync',                     'false'],
                ['debug.hwui.level',                             '0'],
                // Gralloc UBWC compression
                ['debug.gralloc.enable_fb_ubwc',                 '1'],
                ['vendor.gralloc.enable_fb_ubwc',                '1'],
                // System perf
                ['persist.device_config.runtime_native.usap_pool_enabled', 'true'],
                ['persist.sys.perf.topAppRenderThreadBoost.enable', 'true'],
                ['persist.sys.gpu.working_thread_priority',      '1'],
                // Graphite disable
                ['debug.hwui.use_skia_graphite',                 'false'],
                // blur: ENABLED in GL mode — GL blur uses standard EGL paths, works correctly.
                // Disabling breaks WindowBlurBehind on Samsung One UI / MIUI.
                // ro.sf.blurs_are_expensive hints apps to reduce blur requests (still useful)
                ['ro.sf.blurs_are_expensive',                    '1'],
                // ── 7 crash-fix props — MUST be explicitly set, never left to OEM default ─────
                // graphics.gpu.profiler.support=false: OEM default is often true → Snapdragon
                // Profiler intercepts GL calls with wrong function table for custom driver → SIGSEGV
                // on any GL draw call. Must be explicitly false to prevent profiler hooking.
                ['graphics.gpu.profiler.support',                'false'],
                // use_gpu_pixel_buffers=false: PBO readback race on custom Adreno firmware.
                // PBO async readback races with HWUI's synchronous fence wait → SIGSEGV during
                // screenshots, multitasking transitions, and app-to-app switches.
                ['debug.hwui.use_gpu_pixel_buffers',             'false'],
                // recycled_buffer_cache_size=4: AOSP default. OEM ROMs sometimes set this to 0,
                // causing constant buffer reallocation → GPU memory fragmentation → OOM crashes.
                ['debug.hwui.recycled_buffer_cache_size',        '4'],
                // skip_empty_damage=true: Skip GPU work for unchanged frame regions.
                // Must be explicitly set — OEM default false causes unnecessary redraws on
                // custom drivers that don't track dirty regions correctly.
                ['debug.hwui.skip_empty_damage',                 'true'],
                // filter_test_overhead=false: Disables per-draw-call overhead measurement.
                // OEM default sometimes true → CPU stalls inserted between GL calls for timing
                // → sporadic frame drops and ANR-like pauses on heavy scenes.
                ['debug.hwui.filter_test_overhead',              'false'],
                // nv_profiling=false: Nvidia-originated profiling hook. On Adreno custom drivers
                // this attaches an incompatible profiling callback → SIGSEGV on shader compile.
                ['debug.hwui.nv_profiling',                      'false'],
                // 8bit_hdr_headroom=false: Disables HDR headroom tone-mapping in 8bpc GL path.
                // Custom Adreno drivers lack the HDR metadata pipeline this expects → undefined
                // behaviour in the tone-map shader → GPU fault / context reset on HDR content.
                ['debug.hwui.8bit_hdr_headroom',                 'false'],
                // ── HWUI render caches — reduce texture/layer upload stalls in GL mode ──
                ['debug.hwui.texture_cache_size',                '72'],  // 72MB (default 24MB)
                ['debug.hwui.layer_cache_size',                  '48'],  // 48MB (default 16MB)
                ['debug.hwui.path_cache_size',                   '32'],  // 32MB (default  4MB)
                // HW path enforcement — mirror system.prop entries; OEM init scripts may reset these
                ['debug.sf.hw',                                  '1'],
                ['persist.sys.ui.hw',                            '1'],
                ['debug.egl.hw',                                 '1'],
                ['debug.egl.profiler',                           '0'],
                ['debug.egl.trace',                              '0'],
                // Clear Vulkan layers (even in GL mode — prevents leftover skiavk layers causing GL crash)
                ['debug.vulkan.layers',                          ''],
                ['debug.vulkan.dev.layers',                      ''],
                ['persist.graphics.vulkan.validation_enable',    '0'],
                // Ensure HWUI drawing is enabled
                ['debug.hwui.drawing_enabled',                   'true'],
                // Clear OEM vsync disable props
                ['hwui.disable_vsync',                           'false'],
                ['debug.egl.debug_proc',                         ''],
                // Force dark disable — OEM ROMs inject per-frame color inversion shader even in GL mode
                ['debug.hwui.force_dark',                        'false'],
            ];
            for (const [prop, val] of _SKIAGL_PROPS) {
                if (_LIVE_UNSAFE_PROPS.has(prop)) continue; // system.prop only — OEM ROM SF watcher causes crash if set live
                await exec(`resetprop ${prop} "${val}"`);
            }
            // Delete props that are EXCLUSIVELY used by skiavk — Vulkan-specific,
            // SF Vulkan props, and dangerous OEM props. Shared perf/stability props
            // are excluded (they appear in _SKIAGL_PROPS so the filter preserves them).
            const _SKIAGL_DELETE = _CLEAR_ALL.filter(p =>
                !_SKIAGL_PROPS.some(([k]) => k === p)
            );
            for (const p of _SKIAGL_DELETE) {
                await exec(`resetprop --delete ${p} 2>/dev/null || true`);
            }
            logToTerminal('✅ debug.hwui.renderer = skiagl', 'success');
            logToTerminal('ℹ️  debug.renderengine.backend=skiaglthreaded → system.prop only (NOT live-resetprop — OEM SF property watcher crash risk)', 'warn');
            logToTerminal(`✅ ${_SKIAGL_PROPS.length} skiagl + stability + perf + compat props applied live`, 'success');
        } else {
            for (const p of _CLEAR_ALL) {
                await exec(`resetprop --delete ${p} 2>/dev/null || true`);
            }
            logToTerminal('✅ Render props cleared (normal mode)', 'success');
        }

        // ── Step 2: Write to system.prop for persistence across reboots ───────
        const _STRIP_PATTERN = _CLEAR_ALL.map(p => `^${p.replace(/\./g, '\\\\.')}=`).join('|');
        if (MOD_PATH) {
            const sysprPath = `${MOD_PATH}/system.prop`;
            await exec(`[ -f "${sysprPath}" ] || touch "${sysprPath}"`);
            await exec(`awk '!/${_STRIP_PATTERN}/' "${sysprPath}" > "${sysprPath}.tmp" && mv "${sysprPath}.tmp" "${sysprPath}" 2>/dev/null || true`);
            if (renderMode === 'skiavk' || renderMode === 'skiavk_all') {
                // ── Write ALL skiavk props including renderer props to system.prop ──────────
                //
                // UPDATED STRATEGY (matches service.sh post-fix):
                // Module system.prop is processed by the root manager (Magisk/KSU/APatch) via
                // resetprop AFTER magic-mount completes. The custom Vulkan driver overlay is
                // therefore already in place when these props are applied on the next boot.
                // Writing debug.hwui.renderer=skiavk to system.prop (renderengine.backend excluded — pre-SF resetprop only)
                // to system.prop is now SAFE and NECESSARY — it guarantees both HWUI and
                // SurfaceFlinger read the correct renderer from the very first process launch,
                // including SystemUI, without relying on resetprop timing.
                //
                // All other stability/perf/compat/OEM props persist normally.
                // debug.renderengine.backend excluded from system.prop — OEM ROM SF
                // property watchers fire a RenderEngine reinit when value changes at runtime
                // → SF crash → bootloop on 2nd boot. Set via resetprop pre-SF only.
                const _SAFE_SKIAVK_PERSIST = _ALL_SKIAVK_PROPS
                    .filter(([k]) => k !== 'debug.renderengine.backend')
                    .map(([k,v]) => `${k}=${v}`).join('\\n');
                await exec(`printf '${_SAFE_SKIAVK_PERSIST}\\n' >> "${sysprPath}"`);
                logToTerminal(`✅ system.prop: ${_ALL_SKIAVK_PROPS.length - 1} skiavk props written (hwui.renderer=skiavk + HWUI/OEM/perf). renderengine.backend excluded — pre-SF resetprop only (OEM watcher bootloop fix).`, 'success');
            } else if (renderMode === 'skiagl') {
                const _SKIAGL_PERSIST = [
                    'debug.hwui.renderer=skiagl',
                    // debug.renderengine.backend excluded — OEM SF watcher crash risk.
                    // Set via resetprop before SF starts in post-fs-data.sh only.
                    // OEM/hardware gate
                    'persist.sys.force_sw_gles=0',
                    'com.qc.hardware=true',
                    // GL partial-update props disabled — EGL partial update extensions
                    // unreliable on custom Adreno drivers (stale-pixel glitches)
                    'debug.hwui.use_buffer_age=false',
                    'debug.hwui.use_partial_updates=false',
                    'debug.hwui.render_dirty_regions=false',
                    'debug.hwui.webview_overlays_enabled=true',
                    // reduceopstasksplitting=false — AOSP default; true causes rendering artifacts
                    'renderthread.skia.reduceopstasksplitting=false',
                    // Disable Skia tracing/profiling overhead
                    'debug.hwui.skia_tracing_enabled=false',
                    'debug.hwui.skia_use_perfetto_track_events=false',
                    'debug.hwui.capture_skp_enabled=false',
                    'debug.hwui.skia_atrace_enabled=false',
                    // Disable debug overlays
                    'debug.hwui.overdraw=false',
                    'debug.hwui.profile=false',
                    'debug.hwui.show_dirty_regions=false',
                    'debug.hwui.show_layers_updates=false',
                    // EGL shader blob cache
                    'ro.egl.blobcache.multifile=true',
                    'ro.egl.blobcache.multifile_limit=33554432',
                    // HWUI frame scheduling
                    'debug.hwui.render_thread=true',
                    'debug.hwui.use_hint_manager=true',
                    'debug.hwui.target_cpu_time_percent=66',
                    'debug.hwui.skip_eglmanager_telemetry=true',
                    // initialize_gl_always=false — CRASH FIX: see _SKIAGL_PROPS comment above.
                    // ro.zygote.disable_gl_preload=true + initialize_gl_always=true → EGL/Vulkan
                    // init race → SIGSEGV in libEGL/libvulkan on NDK/game app startup.
                    'debug.hwui.initialize_gl_always=false',
                    'debug.hwui.disable_vsync=false',
                    'debug.hwui.level=0',
                    // Gralloc UBWC compression
                    'debug.gralloc.enable_fb_ubwc=1',
                    'vendor.gralloc.enable_fb_ubwc=1',
                    // System perf
                    'persist.device_config.runtime_native.usap_pool_enabled=true',
                    'persist.sys.perf.topAppRenderThreadBoost.enable=true',
                    'persist.sys.gpu.working_thread_priority=1',
                    // Graphite disable; blur ENABLED in GL mode (GL blur uses standard EGL paths)
                    'debug.hwui.use_skia_graphite=false',
                    'ro.sf.blurs_are_expensive=1',
                    // HW path enforcement (OEM init scripts may override these after boot)
                    'debug.sf.hw=1',
                    'persist.sys.ui.hw=1',
                    'debug.egl.hw=1',
                    'debug.egl.profiler=0',
                    'debug.egl.trace=0',
                    // OEM Vulkan layer/validation clearing
                    'debug.vulkan.dev.layers=',
                    'persist.graphics.vulkan.validation_enable=0',
                    // HWUI drawing + vsync enforcement
                    'debug.hwui.drawing_enabled=true',
                    'hwui.disable_vsync=false',
                    'debug.egl.debug_proc=',
                    'debug.hwui.force_dark=false',
                    // ── 7 crash-fix props (see _SKIAGL_PROPS for full root-cause comments) ────
                    // Snapdragon Profiler GL intercept crash (OEM default often true)
                    'graphics.gpu.profiler.support=false',
                    // PBO async readback race → SIGSEGV on screenshots/multitasking
                    'debug.hwui.use_gpu_pixel_buffers=false',
                    // Buffer cache: AOSP default 4 (OEM 0 causes constant realloc → OOM)
                    'debug.hwui.recycled_buffer_cache_size=4',
                    // Skip GPU work for unchanged regions (OEM false causes unnecessary redraws)
                    'debug.hwui.skip_empty_damage=true',
                    // Per-draw-call overhead measurement → CPU stalls between GL calls
                    'debug.hwui.filter_test_overhead=false',
                    // Incompatible profiling callback → SIGSEGV on shader compile
                    'debug.hwui.nv_profiling=false',
                    // HDR headroom tone-map shader not supported by custom Adreno → GPU fault
                    'debug.hwui.8bit_hdr_headroom=false',
                    // ── HWUI render caches — reduce upload stalls in GL mode ──
                    'debug.hwui.texture_cache_size=72',
                    'debug.hwui.layer_cache_size=48',
                    'debug.hwui.path_cache_size=32',
                ];
                await exec(`printf '${_SKIAGL_PERSIST.join('\\n')}\\n' >> "${sysprPath}"`);
                logToTerminal(`✅ system.prop: ${_SKIAGL_PERSIST.length} skiagl+renderengine+stability+perf+compat props written (persists on reboot)`, 'success');
            } else {
                logToTerminal('✅ system.prop: render props cleared', 'success');
            }
        }


        // ── Step 4: Force-stop apps (skiavk_all only) + Step 3 cache clear AFTER ───
        // debug.hwui.renderer is read ONCE per process at first HWUI init, then
        // cached as a static variable (sRenderPipelineType in Properties.cpp). Any
        // process that has already started is stuck on the old renderer until it dies
        // and cold-restarts. We must restart all relevant processes.
        //
        // skiavk / skiagl: props-only. No force-stop, no cache deletion.
        //   resetprop already set the prop live. All NEW processes launched after
        //   this point automatically use the configured renderer. SystemUI keeps its
        //   current renderer for this session — invisible to the user.
        //   Crashing SystemUI for these modes caused: black screen, GMS account loss
        //   (DeadObjectException in AccountManager mid-sync → OAuth tokens wiped →
        //   all Google accounts removed from Settings), Facebook/Messenger crash
        //   (dangling ANativeWindow refs), and Android watchdog bootloop.
        //   Pipeline cache clearing is also SKIPPED for these modes — no apps are
        //   restarted, so old caches cannot cause cold-start crashes this session.
        //   Boot scripts clear caches on next reboot before apps start.
        //   On next reboot, system.prop delivers the correct renderer to every process.
        //
        // skiavk_all: SystemUI is NOT crashed (stability fix). All 3rd-party apps
        //   are force-stopped (Step 4c). THEN per-app pipeline caches are deleted
        //   (Step 3, after force-stop — correct order: kill first, then clear cache).
        //   GMS, GSF, and Meta apps excluded from force-stop to prevent OAuth token
        //   corruption and Google account loss.
        logToTerminal('⏳ Applying renderer switch...', 'info');

        // ══════════════════════════════════════════════════════════════════════════
        // LEGACY DEVICE VULKAN COMPAT GATE — mirrors service.sh's skiavk_all
        // protection chain exactly. Prevents the "skiavk_all crashes everything"
        // scenario on legacy/incompatible devices.
        //
        // ROOT CAUSE of the crash (preserved for reference):
        //   debug.hwui.renderer=skiavk only asks HWUI to TRY Vulkan. On legacy
        //   devices, HWUI reads the prop, attempts vkCreateInstance, fails silently
        //   (VK_ERROR_INCOMPATIBLE_DRIVER, missing KGSL IOCTL, gralloc mismatch,
        //   etc.) and falls back to GL. The prop still reads "skiavk" but apps are
        //   actually on GL. skiavk_all then:
        //     1. Passes the prop check (prop IS "skiavk" — we just set it)
        //     2. Clears GL pipeline caches
        //     3. Force-stops all apps → they restart WITHOUT their GL caches
        //     4. Each app tries Vulkan → fails → GL fallback
        //     5. All apps recompile shaders from scratch simultaneously
        //     6. Facebook (2000+ shaders) + GMS OOM cascade → ALL apps crash on open
        //   The symptom: "every app crashes immediately when opened for 5-10 min"
        //
        // WHEN THIS GATE APPLIES: skiavk AND skiavk_all.
        //   skiavk: gralloc compat props + ICD fix may still be needed to prevent
        //           silent Vulkan fallback even without force-stop.
        //   skiavk_all: all checks required before force-stop is allowed to run.
        // ══════════════════════════════════════════════════════════════════════════

        // ── Shared gate state ─────────────────────────────────────────────────────
        let _vkForceStopAllowed = true;   // becomes false on any failed check
        let _vkGateAbortReason  = '';     // human-readable reason for the UI
        let _vkPropOnlyMode     = false;  // true = apply prop only, skip force-stop

        if (renderMode === 'skiavk' || renderMode === 'skiavk_all') {

            logToTerminal('', 'info');
            logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
            logToTerminal('🔍 LEGACY DEVICE VK COMPAT GATE — running checks...', 'info');
            logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');

            // ── Check 1: Persisted compat flag from a previous boot / apply ──────
            // If service.sh or a previous applyRenderNow already determined this
            // device cannot safely run the force-stop, respect that decision.
            // The user must manually rm /data/local/tmp/adreno_vk_compat to retry
            // (e.g. after a ROM upgrade that fixes the incompatibility).
            const _compatFlagResult = await exec('cat /data/local/tmp/adreno_vk_compat 2>/dev/null || echo ""');
            const _compatFlag = (_compatFlagResult.stdout || '').trim();
            if (_compatFlag === 'prop_only' || _compatFlag === 'incompatible') {
                logToTerminal(`⚠️  [GATE-1] Persisted compat flag: "${_compatFlag}" from a previous boot/apply.`, 'warn');
                logToTerminal('    This device could not safely run skiavk_all force-stop previously.', 'warn');
                logToTerminal('    Force-stop SKIPPED. Props already applied (prop-only mode).', 'warn');
                logToTerminal('    To retry after ROM/driver update: rm /data/local/tmp/adreno_vk_compat', 'info');
                _vkForceStopAllowed = false;
                _vkPropOnlyMode     = true;
                _vkGateAbortReason  = `Persisted compat flag: "${_compatFlag}" — device previously incompatible`;
            } else {
                logToTerminal(`✅ [GATE-1] No persisted incompatibility flag (flag="${_compatFlag || 'none'}")`, 'success');
            }

            // ── Check 2: Structural score from post-fs-data probe ─────────────────
            // post-fs-data.sh writes adreno_vk_compat_score at every boot when
            // skiavk/skiavk_all is configured. Use it here to skip force-stop on
            // structurally blocked devices before wasting time on runtime probes.
            let _structLevel = '';
            let _structScore = 100;
            let _structGralloc = 'unknown';
            let _structReasons = '';
            const _scoreFileResult = await exec('cat /data/local/tmp/adreno_vk_compat_score 2>/dev/null || echo ""');
            if (_scoreFileResult.stdout && _scoreFileResult.stdout.trim()) {
                for (const line of _scoreFileResult.stdout.trim().split('\n')) {
                    const eq = line.indexOf('=');
                    if (eq < 0) continue;
                    const k = line.slice(0, eq).trim();
                    const v = line.slice(eq + 1).trim();
                    if (k === 'LEVEL')   _structLevel   = v;
                    if (k === 'SCORE')   _structScore   = parseInt(v, 10) || 0;
                    if (k === 'GRALLOC') _structGralloc = v;
                    if (k === 'REASONS') _structReasons = v;
                }
                logToTerminal(`✅ [GATE-2] Post-fs-data score: ${_structScore}/100  level: ${_structLevel}  gralloc: ${_structGralloc}`, 'success');
                if (_structReasons) logToTerminal(`    Deductions: ${_structReasons}`, 'info');
            } else {
                logToTerminal('ℹ️  [GATE-2] No adreno_vk_compat_score file — device not yet probed at boot (first apply or normal mode at boot)', 'info');
            }

            // Check auto-degrade marker (post-fs-data degraded this boot already)
            // NOTE: post-fs-data.sh now only degrades on risky+no_driver (driver .so absent).
            // blocked is no longer a degrade trigger there, but old state files may exist.
            const _degradeResult = await exec('cat /data/local/tmp/adreno_skiavk_degraded 2>/dev/null || echo ""');
            const _degradeReason = (_degradeResult.stdout || '').trim();
            if (_degradeReason) {
                // Check if it's a no-driver degrade (hard) vs old blocked degrade (warn only now)
                const _isNoDriver = _degradeReason.includes('no_driver');
                if (_isNoDriver) {
                    logToTerminal(`⛔ [GATE-2] Boot auto-degrade: "${_degradeReason}"`, 'error');
                    logToTerminal('    No Vulkan driver .so found — skiavk cannot function.', 'error');
                    logToTerminal('    Force-stop ABORTED. Props applied in skiagl mode.', 'error');
                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = `No Vulkan driver: ${_degradeReason}`;
                } else {
                    // Old blocked/risky degrade — warn but proceed (user chose skiavk)
                    logToTerminal(`⚠️  [GATE-2] Stale boot auto-degrade marker: "${_degradeReason}"`, 'warn');
                    logToTerminal('    This was set by an older/stricter check. Applying skiavk anyway as requested.', 'warn');
                    logToTerminal('    If Vulkan fails silently, HWUI falls back to GL automatically.', 'warn');
                }
            } else if (_structLevel === 'blocked') {
                // LENIENT: blocked is now a warning, not an abort.
                // Many real devices that work fine with skiavk score "blocked" due to
                // conservative heuristics (old vendor partition, gralloc version mismatch, etc).
                logToTerminal(`⚠️  [GATE-2] Compat score BLOCKED (${_structScore}/100) — applying skiavk anyway`, 'warn');
                logToTerminal(`    Reasons: ${_structReasons || 'see boot log'}`, 'warn');
                logToTerminal('    If Vulkan fails HWUI falls back to GL automatically — no crash, just GL rendering.', 'warn');
                logToTerminal('    Disable skiavk only if you see visual corruption or persistent black screen.', 'warn');
            } else if (_structLevel === 'risky' || _structLevel === 'marginal') {
                logToTerminal(`⚠️  [GATE-2] Compat score ${_structLevel.toUpperCase()} (${_structScore}/100)`, 'warn');
                logToTerminal('    skiavk prop applied. Force-stop disabled as precaution on risky/marginal devices.', 'warn');
                if (renderMode === 'skiavk_all') {
                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = `Compat score ${_structLevel} (${_structScore}/100) — force-stop disabled`;
                }
            } else {
                logToTerminal(`✅ [GATE-2] Structural score OK (${_structScore}/100, level="${_structLevel || 'no score yet'}")`, 'success');
            }

            // ── Info: skiavkthreaded vs debug.hwui.renderer=skiavk ───────────────
            // These are different things. Clarify so the user isn't confused when
            // they see "skiavkthreaded" in dumpsys gfxinfo Pipeline output.
            logToTerminal('ℹ️  [INFO] Renderer notes:', 'info');
            logToTerminal('    debug.hwui.renderer=skiavk → tells HWUI to use the Skia Vulkan backend.', 'info');
            logToTerminal('    debug.renderengine.backend=skiavkthreaded → tells SurfaceFlinger RenderEngine to use threaded Vulkan compositing.', 'info');
            logToTerminal('    Both are set by this module. They are independent props for different subsystems.', 'info');
            logToTerminal('    If Vulkan init fails, HWUI silently falls back to GL — the prop stays "skiavk" but apps run on GL.', 'info');
            logToTerminal('    Use: dumpsys gfxinfo <pkg> | grep Pipeline   to verify actual runtime renderer.', 'info');


            // Some device trees set this to "false" to explicitly disable HWUI Vulkan.
            // HWUI checks this BEFORE vkCreateInstance — if false, the skiavk prop
            // is silently ignored and all apps run on GL. Force-stop would then:
            //   clear GL caches → apps restart → HWUI ignores skiavk → GL fallback
            //   → mass shader recompile from scratch → OOM → cascade crashes.
            if (_vkForceStopAllowed || renderMode === 'skiavk') {
                const _useVkResult = await exec('getprop ro.hwui.use_vulkan 2>/dev/null || echo ""');
                const _useVk = (_useVkResult.stdout || '').trim();
                if (_useVk === 'false' || _useVk === '0') {
                    logToTerminal(`⛔ [GATE-3] ro.hwui.use_vulkan="${_useVk}" — ROM device tree disables HWUI Vulkan.`, 'error');
                    logToTerminal('    HWUI ignores debug.hwui.renderer=skiavk when this is false.', 'error');
                    logToTerminal('    Force-stop ABORTED — apps restart on GL with no benefit.', 'error');
                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = `ro.hwui.use_vulkan="${_useVk}" — ROM device tree disables HWUI Vulkan`;
                    // Persist so future apply-nows don't repeat this
                    await exec('echo "prop_only" > /data/local/tmp/adreno_vk_compat 2>/dev/null || true');
                } else {
                    logToTerminal(`✅ [GATE-3] ro.hwui.use_vulkan="${_useVk || 'not set (default enabled)'}"`, 'success');
                }
            }

            // ── Check 4: Vulkan ICD .so existence ────────────────────────────────
            // Without a Vulkan ICD, vkCreateInstance always returns
            // VK_ERROR_INCOMPATIBLE_DRIVER. HWUI falls back to GL silently.
            // Force-stop with no Vulkan ICD = guaranteed OOM cascade.
            if (_vkForceStopAllowed || renderMode === 'skiavk') {
                const _vkSoCheck = await exec(
                    'for f in /vendor/lib64/hw/vulkan.*.so /vendor/lib/hw/vulkan.*.so ' +
                    '/system/lib64/hw/vulkan.*.so /system/lib/hw/vulkan.*.so ' +
                    '/vendor/lib64/libvulkan.so /system/lib64/libvulkan.so; do ' +
                    '[ -f "$f" ] && echo "found:$f" && break; done 2>/dev/null || echo "none"'
                );
                const _vkSoOut = (_vkSoCheck.stdout || '').trim();
                if (!_vkSoOut || _vkSoOut === 'none' || !_vkSoOut.startsWith('found:')) {
                    logToTerminal('⛔ [GATE-4] No Vulkan ICD .so found in vendor/system lib dirs.', 'error');
                    logToTerminal('    vkCreateInstance → VK_ERROR_INCOMPATIBLE_DRIVER → HWUI silent GL fallback.', 'error');
                    logToTerminal('    Force-stop ABORTED — applying skiavk prop has no real effect.', 'error');
                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = 'No Vulkan ICD .so found — skiavk will always fail silently';
                    await exec('echo "incompatible" > /data/local/tmp/adreno_vk_compat 2>/dev/null || true');
                } else {
                    logToTerminal(`✅ [GATE-4] Vulkan ICD found: ${_vkSoOut.replace('found:', '')}`, 'success');
                }
            }

            // ── Check 5: ro.hardware.vulkan ICD fix ──────────────────────────────
            // OEM ROMs set ro.hardware.vulkan to the SoC codename (sm6115, kona,
            // lahaina) instead of "adreno". The Vulkan loader opens
            // vulkan.${ro.hardware.vulkan}.so → ENOENT → VK_ERROR_INCOMPATIBLE_DRIVER.
            // Fix it now if vulkan.adreno.so exists, so vkCreateInstance succeeds.
            const _hwVkResult = await exec('getprop ro.hardware.vulkan 2>/dev/null || echo ""');
            const _hwVkVal    = (_hwVkResult.stdout || '').trim();
            if (_hwVkVal && _hwVkVal !== 'adreno') {
                const _adrSoCheck = await exec(
                    '[ -f /vendor/lib64/hw/vulkan.adreno.so ] || ' +
                    '[ -f /vendor/lib/hw/vulkan.adreno.so ] && echo "yes" || echo "no"'
                );
                if ((_adrSoCheck.stdout || '').trim() === 'yes') {
                    await exec('resetprop ro.hardware.vulkan adreno 2>/dev/null || true');
                    logToTerminal(`🔧 [GATE-5] ro.hardware.vulkan: "${_hwVkVal}" → "adreno" (ICD fix applied live)`, 'warn');
                } else {
                    logToTerminal(`⚠️  [GATE-5] ro.hardware.vulkan="${_hwVkVal}" but vulkan.adreno.so absent — ICD fix skipped`, 'warn');
                }
            } else {
                logToTerminal(`✅ [GATE-5] ro.hardware.vulkan="${_hwVkVal || 'not set (uses icd.d/)'}"`, 'success');
            }

            // ── Check 6: Gralloc WSI compat props ────────────────────────────────
            // On old-vendor devices with gralloc2 or gralloc3, the Vulkan swapchain
            // buffer allocation path is broken in specific ways. Apply mitigations:
            //   gralloc2/3: disable SF backpressure stall (fence interop broken →
            //     backpressure stall waits forever on a fence that never signals →
            //     swapchain deadlock → black screen after first frame).
            //   gralloc2/3: cap SF buffer pool (gralloc2/3 has hard allocator pool
            //     limits; Vulkan swapchain exhausts them unless capped at 2 acquired).
            //   gralloc2/3: clear OEM validation layers (wrong ABI → vkCreateInstance
            //     fails with VK_ERROR_LAYER_NOT_PRESENT → every app crashes at init).
            // These mirror BLOCK B in post-fs-data.sh and BLOCK C in service.sh.
            if (renderMode === 'skiavk' || renderMode === 'skiavk_all') {
                if (_structGralloc === '2' || _structGralloc === '3') {
                    logToTerminal(`🔧 [GATE-6] Gralloc ${_structGralloc} (old vendor) — applying WSI compat props...`, 'warn');
                    await exec('resetprop debug.sf.disable_backpressure 0 2>/dev/null || true');
                    await exec('resetprop debug.sf.max_frame_buffer_acquired_buffers 2 2>/dev/null || true');
                    await exec('resetprop debug.vulkan.dev.layers "" 2>/dev/null || true');
                    await exec('resetprop debug.vulkan.layers "" 2>/dev/null || true');
                    await exec('resetprop persist.graphics.vulkan.validation_enable 0 2>/dev/null || true');
                    logToTerminal(`    ✅ Gralloc ${_structGralloc} WSI compat: backpressure=0, buffer_acquired=2, layers cleared`, 'success');
                } else if (_structGralloc !== 'unknown') {
                    logToTerminal(`✅ [GATE-6] Gralloc ${_structGralloc} — no WSI compat workarounds needed`, 'success');
                } else {
                    logToTerminal('ℹ️  [GATE-6] Gralloc version unknown (no boot-time score) — WSI compat props skipped', 'info');
                }
            }

            // ── Check 7: KGSL device accessible ──────────────────────────────────
            // /dev/kgsl-3d0 must exist. If not, there's no GPU at all and Vulkan
            // is structurally impossible regardless of any other check.
            if (_vkForceStopAllowed) {
                const _kgslCheck = await exec('[ -e /dev/kgsl-3d0 ] && echo "yes" || echo "no"');
                if ((_kgslCheck.stdout || '').trim() !== 'yes') {
                    logToTerminal('⛔ [GATE-7] /dev/kgsl-3d0 not found — no GPU device. Vulkan impossible.', 'error');
                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = '/dev/kgsl-3d0 absent — no GPU device';
                } else {
                    logToTerminal('✅ [GATE-7] /dev/kgsl-3d0 accessible', 'success');
                }
            }

            // ── Check 8: KGSL game protection ────────────────────────────────────
            // UE4/native-Vulkan games (PUBG, Fortnite, CoD, Genshin) hold open
            // KGSL contexts. Concurrent force-stops while a game is running races
            // the KGSL context allocation table → permanent corruption this boot →
            // vkCreateDevice fails for every subsequent app until reboot.
            // Mirrors the KGSL protection check in service.sh's skiavk_all subshell.
            if (_vkForceStopAllowed && renderMode === 'skiavk_all') {
                const _gamePackages = [
                    'com.tencent.ig', 'com.pubg.krmobile', 'com.pubg.imobile',
                    'com.vng.pubgmobile', 'com.rekoo.pubgm', 'com.tencent.tmgp.pubgmhd',
                    'com.epicgames.', 'com.activision.callofduty.shooter',
                    'com.garena.game.codm', 'com.tencent.tmgp.cod', 'com.vng.codmvn',
                    'com.miHoYo.GenshinImpact', 'com.cognosphere.GenshinImpact',
                    'com.miHoYo.enterprise.HSRPrism', 'com.HoYoverse.hkrpgoversea',
                    'com.levelinfinite.hotta', 'com.proximabeta.mfh',
                    'com.HoYoverse.Nap', 'com.miHoYo.ZZZ'
                ];
                // Read all cmdlines from /proc — same technique as service.sh daemon
                const _procResult = await exec(
                    'for f in /proc/[0-9]*/cmdline; do [ -f "$f" ] && ' +
                    'tr "\\0" " " < "$f" 2>/dev/null; echo; done 2>/dev/null | head -200'
                );
                const _procOut = _procResult.stdout || '';
                let _gameRunning = false;
                let _runningGame = '';
                for (const pkg of _gamePackages) {
                    if (_procOut.includes(pkg)) {
                        _gameRunning = true;
                        _runningGame = pkg;
                        break;
                    }
                }
                if (_gameRunning) {
                    logToTerminal(`⛔ [GATE-8] Native-Vulkan game running: "${_runningGame}"`, 'error');
                    logToTerminal('    Force-stopping apps while a KGSL game runs corrupts the KGSL context table.', 'error');
                    logToTerminal('    vkCreateDevice will fail for ALL apps until reboot.', 'error');
                    logToTerminal('    Close the game first, then apply skiavk_all.', 'error');
                    _vkForceStopAllowed = false;
                    _vkGateAbortReason  = `Native-Vulkan game running: ${_runningGame}`;
                } else {
                    logToTerminal('✅ [GATE-8] No native-Vulkan games running — KGSL safe', 'success');
                }
            }

            // ── Check 9: SystemUI Vulkan canary (THE CRITICAL CHECK) ─────────────
            //
            // This is the most important check. It answers: "Is Vulkan actually
            // working on this device RIGHT NOW?" not just "could it theoretically work?"
            //
            // SystemUI has been running since early boot. dumpsys gfxinfo reports its
            // ACTUAL render pipeline (what HWUI is really using), not what the prop says.
            // "Skia (Vulkan)" appears in the output for every active Vulkan surface.
            //
            // If count == 0: HWUI read "skiavk", attempted vkCreateInstance, failed
            // (silently), fell back to GL. Props say "skiavk" — reality is GL.
            //
            // If we force-stop apps in this state:
            //   → GL caches already cleared (we cleared them above)
            //   → Apps restart → HWUI tries Vulkan → fails → GL fallback
            //   → No GL caches → must recompile every shader from scratch
            //   → All apps doing this simultaneously → OOM cascade
            //   → Every app crashes on open for 5-10 minutes
            //   → Root cause of ALL "skiavk_all crashes everything" user reports
            //
            // If count > 0: Vulkan is real, working, hardware-confirmed.
            //   Force-stop is safe — restarted apps will also get working Vulkan.
            //
            // Only runs for skiavk_all (force-stop path). skiavk (prop-only) doesn't
            // need this — if Vulkan fails silently, no caches are cleared and no apps
            // are restarted, so there's no OOM cascade.
            if (_vkForceStopAllowed && renderMode === 'skiavk_all') {
                logToTerminal('⏳ [GATE-9] SystemUI Vulkan canary: querying dumpsys gfxinfo...', 'info');
                logToTerminal('    (This is the definitive runtime check: is Vulkan ACTUALLY running?)', 'info');

                // dumpsys gfxinfo may take a moment; SystemUI must be fully drawn
                await new Promise(r => setTimeout(r, 1500));

                const _dumpsysResult = await exec(
                    'dumpsys gfxinfo com.android.systemui 2>/dev/null | grep -c "Skia (Vulkan)" 2>/dev/null || echo "0"'
                );
                const _vkCount = parseInt((_dumpsysResult.stdout || '0').trim(), 10) || 0;

                if (_vkCount === 0) {
                    // Also capture the Pipeline line for the log — mirrors service.sh Loophole 4
                    const _pipeResult = await exec(
                        'dumpsys gfxinfo com.android.systemui 2>/dev/null | grep -i "Pipeline" | head -1 || echo ""'
                    );
                    const _livePropResult = await exec('getprop debug.hwui.renderer 2>/dev/null || echo ""');
                    const _sysUiPipe  = (_pipeResult.stdout  || '').trim() || 'not found';
                    const _liveProp   = (_livePropResult.stdout || '').trim();

                    logToTerminal('', 'error');
                    logToTerminal('⛔ ⛔ ⛔  VK CANARY FAILED — FORCE-STOP ABORTED  ⛔ ⛔ ⛔', 'error');
                    logToTerminal(`    SystemUI pipeline: "${_sysUiPipe}"`, 'error');
                    logToTerminal(`    Live renderer prop: "${_liveProp}"`, 'error');
                    logToTerminal('    Skia(Vulkan) surface count: 0', 'error');
                    logToTerminal('', 'error');
                    logToTerminal('    DIAGNOSIS: HWUI read skiavk but Vulkan init FAILED SILENTLY.', 'error');
                    logToTerminal('    Every app is actually running on GL despite prop saying skiavk.', 'error');
                    logToTerminal('', 'error');
                    logToTerminal('    IMPACT if force-stop had run:', 'error');
                    logToTerminal('      GL caches cleared + apps killed → restart on GL without caches', 'error');
                    logToTerminal('      → mass concurrent shader recompile → OOM → ALL apps crash on open', 'error');
                    logToTerminal('', 'error');
                    logToTerminal('    Possible root causes (check boot log for details):', 'error');
                    logToTerminal('      • Incomplete Vulkan stack (missing extensions/KGSL IOCTL)', 'error');
                    logToTerminal('      • vendor_init overrode prop after our resetprop', 'error');
                    logToTerminal('      • ro.hardware.vulkan points to wrong ICD', 'error');
                    logToTerminal('      • Gralloc version mismatch (swapchain alloc fails)', 'error');
                    logToTerminal('      • SELinux blocking /dev/kgsl-3d0 for app processes', 'error');
                    logToTerminal('', 'error');
                    logToTerminal('    skiavk prop remains ACTIVE — new apps will attempt Vulkan.', 'error');
                    logToTerminal('    To retry: rm /data/local/tmp/adreno_vk_compat && reboot', 'error');
                    logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'error');

                    _vkForceStopAllowed = false;
                    _vkPropOnlyMode     = true;
                    _vkGateAbortReason  = `SystemUI Vulkan canary FAILED (0 Skia(Vulkan) surfaces, pipeline="${_sysUiPipe}")`;

                    // Persist so future apply-nows and future service.sh boots both skip force-stop
                    await exec('echo "prop_only" > /data/local/tmp/adreno_vk_compat 2>/dev/null || true');
                    logToTerminal('    Persisted "prop_only" flag → future apply-nows and boot scripts skip force-stop.', 'warn');

                } else {
                    logToTerminal(`✅ [GATE-9] SystemUI Vulkan canary PASSED: ${_vkCount} Skia(Vulkan) surface(s) confirmed.`, 'success');
                    logToTerminal('    Vulkan is real and working on this device — force-stop is SAFE.', 'success');
                    // Clear any stale incompatibility flag — device is working fine
                    await exec('echo "confirmed" > /data/local/tmp/adreno_vk_compat 2>/dev/null || true');
                }
            }

            // ── Gate summary ──────────────────────────────────────────────────────
            logToTerminal('', 'info');
            if (!_vkForceStopAllowed && renderMode === 'skiavk_all') {
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
                logToTerminal('⚠️  LEGACY COMPAT GATE: Force-stop SKIPPED for this device.', 'warn');
                logToTerminal(`    Reason: ${_vkGateAbortReason}`, 'warn');
                logToTerminal('    Props have been applied live — new apps will use skiavk.', 'warn');
                logToTerminal('    Existing background apps keep their old renderer until they', 'warn');
                logToTerminal('    close and reopen naturally (no OOM risk).', 'warn');
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'warn');
            } else if (renderMode === 'skiavk_all') {
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'success');
                logToTerminal('✅ LEGACY COMPAT GATE: All checks passed — force-stop AUTHORIZED.', 'success');
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'success');
            } else {
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
                logToTerminal('✅ LEGACY COMPAT GATE: skiavk prop-only checks complete.', 'success');
                logToTerminal('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━', 'info');
            }
            logToTerminal('', 'info');

        } // end skiavk/skiavk_all compat gate block

        // ══════════════════════════════════════════════════════════════════════════
        // END LEGACY DEVICE VULKAN COMPAT GATE
        // _vkForceStopAllowed is now authoritative for whether force-stop may run.
        // ══════════════════════════════════════════════════════════════════════════

        if (renderMode === 'skiavk_all' && !_vkForceStopAllowed) {
            // Gate blocked force-stop — treat as skiavk prop-only for the rest of this function.
            // Props are already live (applied above). Log and skip to settle delay.
            logToTerminal('ℹ️  skiavk_all downgraded to skiavk prop-only by compat gate.', 'info');
            logToTerminal('    Background apps will switch to skiavk naturally on next cold-start.', 'info');
            await new Promise(r => setTimeout(r, 2000));
            await loadRenderStatus();
            showToast(`✅ skiavk props applied (force-stop skipped — legacy device compat gate)`);
            setLoading(false);
            return;
        }

        if (renderMode === 'skiavk_all') {
            // ── Step 4a: SystemUI — NOT crashed (intentional, permanent fix) ────
            //
            // ROOT CAUSE ANALYSIS — why crashing SystemUI caused ALL user problems:
            //
            // When "Apply Now" is clicked the user is ACTIVELY using the device.
            // Firing am crash com.android.systemui at this moment causes:
            //
            //   1. SystemUI dies → SurfaceFlinger loses ALL layer references
            //      → BLACK SCREEN for 5–15 seconds
            //
            //   2. GMS AccountManager is mid-OAuth-sync (holds live Binder to
            //      SystemUI's AccountManagerService proxy). SystemUI death delivers
            //      DeadObjectException → AccountManager marks ALL OAuth tokens
            //      invalid → removes EVERY Google account from Settings.
            //      ("Google accounts disappear" symptom)
            //
            //   3. Meta apps (Facebook/Messenger/Instagram) hold ANativeWindow
            //      handles from SF's first draw. When SF loses layer refs on
            //      SystemUI crash, handles go dangling. Next draw → stale pointer
            //      dereference → SIGSEGV → instant app crash.
            //
            //   4. On custom ROMs: services die in solidarity with SystemUI
            //      (tight death dependencies). Android watchdog counts 3+ crashes
            //      in 5 min → system_server kill → ROM logo → reboot.
            //
            // FIX: Do NOT crash SystemUI. It is NOT necessary:
            //   - resetprop already set debug.hwui.renderer=skiavk LIVE (Step 2).
            //   - Every NEW process opened after this point reads skiavk.
            //   - SystemUI keeps its current renderer for THIS session.
            //     (It's already rendering at 60fps; the difference is invisible.)
            //   - After reboot: system.prop delivers skiavk to SystemUI from init.
            //     No crash needed. Ever.
            //
            // Force-stops in Step 4c below still run — they make background apps
            // cold-start fresh with skiavk on next user-open. These don't touch
            // SystemUI, GMS, the launcher, or any foreground process.
            logToTerminal('ℹ️ [skiavk_all] SystemUI NOT crashed — stability fix (props already live via resetprop)', 'info');
            logToTerminal('ℹ️ All newly opened apps use skiavk immediately. SystemUI uses new renderer after reboot.', 'info');

            // ── Step 4c: Force-stop all 3rd-party apps (THROTTLED) ─────────────
            //
            // PURPOSE: Make background apps cold-start with skiavk on next open.
            // debug.hwui.renderer is cached per-process at first HWUI init. Apps
            // already running when resetprop fired still have the old renderer.
            // Force-stopping them makes them exit and re-read the prop on next launch.
            //
            // WHY THROTTLED (150ms between each package):
            //   Each app holds open /dev/kgsl-3d0 FDs. KGSL (Qualcomm kernel GPU
            //   driver) runs per-FD context cleanup on process death. Killing hundreds
            //   of apps simultaneously → hundreds of concurrent KGSL teardowns →
            //   race condition in KGSL's context allocation table (on custom Adreno
            //   drivers) → entries left corrupted → EVERY new app that opens
            //   /dev/kgsl-3d0 gets a broken context → vkCreateDevice fails →
            //   ALL apps crash on open forever until reboot.
            //   150ms gives KGSL time to fully complete each teardown serially.
            //
            // am kill-all is NEVER used — kills all cached procs simultaneously,
            // which is exactly the concurrent KGSL teardown problem above.
            //
            // EXCLUSIONS: GMS/GSF/Play (RemoteException cascade on custom ROMs),
            //   Meta apps (GMS OAuth token corruption), launchers (jarring restart),
            //   SystemUI (black screen + GMS account loss + reboot loop).
            logToTerminal('⏳ [skiavk_all] Force-stopping apps (throttled 150ms, GMS/Meta excluded)...', 'info');
            // BUG FIX: Previously the game exclusion list was hardcoded here, so
            // any game the user added via WebUI or manually to game_exclusion_list.sh
            // was still force-stopped, causing the exact dual-VkDevice crash we're
            // trying to prevent. Now we use _gameExclPkgs (already loaded from the
            // saved game_exclusion_list.sh at WebUI init) so the force-stop exclusions
            // always match the daemon's exclusion list exactly.
            //
            // Glob wildcard entries (e.g. "com.epicgames.*") are expanded here:
            // we strip the trailing ".*" and use startsWith() for prefix matching,
            // exactly mirroring the shell daemon's `case "$_cl" in *"${_ge_base}"*)`.
            const _gameExclExact   = new Set(_gameExclPkgs.filter(e => !e.endsWith('.*')));
            const _gameExclPrefixes = _gameExclPkgs
                .filter(e => e.endsWith('.*'))
                .map(e => e.slice(0, -1)); // strip trailing '*', keep trailing '.'

            const _isGameExcluded = (p) => {
                if (_gameExclExact.has(p)) return true;
                return _gameExclPrefixes.some(prefix => p.startsWith(prefix));
            };

            const pkgListResult = await exec('pm list packages -3 2>/dev/null');
            if (pkgListResult.stdout) {
                const pkgs = pkgListResult.stdout.trim().split('\n')
                    .map(l => l.replace(/^package:/, '').trim())
                    .filter(p => p &&
                        // ── System / framework packages ───────────────────────
                        !p.startsWith('android') &&
                        !p.startsWith('com.android.') &&
                        // ── GMS / Play — RemoteException cascade on custom ROMs
                        !p.startsWith('com.google.android.gms') &&
                        !p.startsWith('com.google.android.gsf') &&
                        p !== 'com.android.vending' &&
                        // ── SystemUI — black screen + GMS account loss + bootloop
                        p !== 'com.android.systemui' &&
                        // ── Meta apps — hold live GMS AccountManager Binder for
                        //    OAuth sync. Killing mid-sync → DeadObjectException on
                        //    AccountManager thread → ALL Google OAuth tokens invalid
                        //    → every Google account removed from Settings.
                        p !== 'com.facebook.katana' &&
                        p !== 'com.facebook.orca' &&
                        p !== 'com.facebook.lite' &&
                        p !== 'com.facebook.mlite' &&
                        p !== 'com.instagram.android' &&
                        p !== 'com.instagram.lite' &&
                        p !== 'com.whatsapp' &&
                        p !== 'com.whatsapp.w4b' &&
                        // ── Game exclusion list (dynamic — matches daemon exactly) ─
                        // UE4/native-Vulkan games create their own VkDevice; force-
                        // stopping them while skiavk is active triggers a cold start
                        // where both the game engine and HWUI race to call
                        // vkCreateDevice → SIGSEGV on custom Adreno drivers.
                        // The game daemon protects these at runtime — they must NOT
                        // be force-stopped here.
                        !_isGameExcluded(p));
                let stopped = 0;
                logToTerminal(`ℹ️ [skiavk_all] Game exclusion list: ${_gameExclPkgs.length} packages excluded from force-stop`, 'info');
                for (const pkg of pkgs) {
                    await exec(`am force-stop "${pkg}" 2>/dev/null || true`);
                    stopped++;
                    // Throttle: 150ms between kills — lets KGSL complete context
                    // teardown before the next SIGKILL arrives. Prevents concurrent
                    // KGSL context table corruption on custom Adreno drivers.
                    await new Promise(r => setTimeout(r, 150));
                }
                logToTerminal(`✅ [skiavk_all] ${stopped} apps force-stopped (throttled, GMS/Meta/Play/SystemUI/game-excl excluded)`, 'success');
            }

            // ── Step 3 (skiavk_all ONLY, AFTER force-stop): Clear stale pipeline caches ──
            //
            // CORRECT ORDER: apps are force-stopped FIRST (Step 4c above), THEN we delete
            // their pipeline caches. This guarantees no app process has its pipeline cache
            // directory open when we delete it.
            //
            // WHY CACHE CLEARING IS NEEDED HERE:
            // When switching GL → Vulkan, per-app pipeline cache dirs contain GL-format
            // VkPipelineCache data. On cold start with skiavk active, HWUI passes this as
            // VkPipelineCacheCreateInfo.pInitialData. The Vulkan driver sees the wrong cache
            // header magic → VK_ERROR_FORMAT_FEATURE_NOT_SUPPORTED or GPU fault → SIGSEGV.
            // Every app that was running before Apply Now will crash on first open after
            // skiavk_all force-stop until their caches are regenerated. Deleting them here
            // ensures clean Vulkan caches on cold-start.
            //
            // NOTE: /data/misc/hwui/ is deliberately NOT deleted — SF uses it for its own
            // pipeline cache and has it open while running. Boot scripts handle it at boot
            // before SF starts. Deleting it here causes SF write errors → SF crash.
            logToTerminal('⏳ [skiavk_all] Clearing stale per-app Skia pipeline caches (apps already stopped)...', 'info');
            // Per-app Skia pipeline caches — format-incompatible between GL and Vulkan
            await exec('find /data/user_de/0 -maxdepth 2 -type d -name "app_skia_pipeline_cache" -exec rm -rf {} + 2>/dev/null; true');
            // Fallback: legacy /data/data path (direct boot disabled devices)
            await exec('find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" -exec rm -rf {} + 2>/dev/null; true');
            // Per-app shader journal manifests (contain GL pipeline keys — invalid under Vulkan)
            await exec('find /data/user_de/0 -maxdepth 2 -name "*.shader_journal" -delete 2>/dev/null; true');
            // Per-app Skia shader caches (format-incompatible between GL and Vulkan)
            await exec('find /data/user_de/0 -maxdepth 2 -type d \\( -name "skia_shaders" -o -name "shader_cache" \\) -exec rm -rf {} + 2>/dev/null; true');
            logToTerminal('✅ [skiavk_all] Per-app Skia pipeline caches cleared (prevents GL→VK cache format mismatch crash on cold-start)', 'success');
        }

        // am kill-all — INTENTIONALLY NOT USED.
        // It kills ALL cached processes simultaneously → mass concurrent KGSL
        // teardowns → permanent KGSL context table corruption for the boot session.
        // The throttled loop above already handles background apps safely.
        logToTerminal('ℹ️ am kill-all skipped (prevents KGSL corruption on custom Adreno drivers)', 'info');

        // Settle delay — let GMS Binder connections re-establish after force-stops.
        await new Promise(r => setTimeout(r, 3000));
        logToTerminal('✅ Services settled (3s). Apps will cold-start with new renderer when opened.', 'success');

        // ── App-triggered renderer switching daemon respawn ───────────────────
        //
        // WHY RESPAWNED HERE (not just at boot):
        //   BUG FIX 1: service.sh only launches the daemon at boot when
        //   RENDER_MODE is already skiavk. Switching via Apply Now from a
        //   different mode left zero skiagl switching protection. Now we
        //   always kill+respawn with the current exclusion list.
        //
        //   BUG FIX 2: If the user added packages via WebUI after boot, the
        //   running daemon still had the old list baked in. Respawning always
        //   uses the current _gameExclPkgs from the live WebUI state.
        //
        // ARCHITECTURE — EVENT-DRIVEN (not polling):
        //   The daemon tails Android's 'events' logcat buffer for am_proc_start
        //   and am_proc_died events. These are emitted by ActivityManagerService
        //   at process fork/death. The daemon blocks on logcat read — zero CPU
        //   when no monitored package is running. Reacts within <100ms of fork.
        //
        //   am_proc_start format (-v tag):
        //     I/am_proc_start: [user,pid,uid,processName,type,component]
        //   processName field (index 4, 1-based comma-split) = package name.
        //   Matches "pkg:processName" for multi-process apps too.
        //
        // WHY skiagl (NOT "skiaglthreaded") for debug.hwui.renderer:
        //   HWUI Properties.cpp only recognises three values:
        //   "skiagl" → SkiaGL, "skiavk" → SkiaVK, anything else (including
        //   "skiaglthreaded") → falls through to legacy "opengl" renderer
        //   (Android 8 era). "skiagl" runs on HWUI's existing RenderThread —
        //   it IS threaded. "skiaglthreaded" is only valid for
        //   debug.renderengine.backend (SurfaceFlinger compositor), not HWUI.
        //
        // WHY debug.renderengine.backend is NOT touched:
        //   Controls SurfaceFlinger compositor. OEM ROM SF property watchers
        //   trigger render engine reinitialization on live change → SF crash
        //   → all apps lose their window surfaces. Left at boot value.
        //
        // STATE: Shared via /data/local/tmp/adreno_daemon_active (file).
        //   POSIX sh pipeline runs in a subshell; shell variables don't
        //   propagate back. The file is the IPC channel between subshells.
        //   "1" = switched to skiagl. "0" = on restore renderer.
        if (renderMode === 'skiavk' || renderMode === 'skiavk_all') {
            try {
                const daemonPath = '/data/local/tmp/adreno_game_daemon.sh';
                const exclPkgs   = _gameExclPkgs.join(' ');

                // Kill any stale daemon before writing the new one.
                await exec(`pkill -f '${daemonPath}' 2>/dev/null; true`);

                // ── Build the daemon script ─────────────────────────────────────
                // Each shell script line is a separate element in scriptLines[].
                // Lines are written using printf '%s\n' 'line' — single-quoted args
                // preserve ALL shell metacharacters literally (no $ expansion during
                // write). GAME_EXCLUSION_PKGS gets its own printf to allow the JS
                // variable interpolation of exclPkgs without shell escaping issues.
                //
                // Backslash note: JS '\\*' → runtime string '\*' → shell file '\*'
                // → when daemon runs, ${_ge%\*} strips trailing literal * wildcard. ✓
                const scriptLines = [
                    // [0] shebang (written first, creates/truncates the file)
                    '#!/system/bin/sh',
                    // [1] GAME_EXCLUSION_PKGS (written with separate printf for JS interpolation)
                    `GAME_EXCLUSION_PKGS="${exclPkgs}"`,
                    // [2..] body lines (appended in one printf call)
                    // FIX: hardcode _RESTORE=skiavk. Reading live prop captures 'skiavk_all'
                    // (invalid renderer value) if a prior daemon exit left that stale prop,
                    // causing a bad restore on the next game exit. This daemon is only
                    // spawned for skiavk/skiavk_all modes; restore target is always 'skiavk'.
                    '_RESTORE=skiavk',
                    '_SF=/data/local/tmp/adreno_daemon_active',
                    'printf "0\\n" > "$_SF" 2>/dev/null || true',
                    // /proc scanner — returns 0 if any excluded pkg is alive
                    // IFS=read -r stops at NUL: for Android apps, /proc/pid/cmdline =
                    // "com.pkg\0arg\0..." so read returns exactly the package name. ✓
                    '_ae() { local _cf _rb _ge _gb;',
                    '  for _cf in /proc/[0-9]*/cmdline; do',
                    '    [ -f "$_cf" ] || continue',
                    '    { IFS= read -r _rb; } < "$_cf" 2>/dev/null || continue',
                    '    [ -n "$_rb" ] || continue',
                    '    for _ge in $GAME_EXCLUSION_PKGS; do _gb="${_ge%\\*}";',
                    '      case "$_rb" in *"${_gb}"*) return 0;; esac',
                    '    done',
                    '  done; return 1; }',
                     // FIX: _ie() now uses exact glob matching, same as _game_pkg_excluded().
                     // Prior substring match (*"${_gb}"*) caused false positives:
                     // e.g. com.tencent.ig pattern would match com.tencent.igplugin.
                     '_ie() { local _p="$1" _ge; for _ge in $GAME_EXCLUSION_PKGS; do',
                     '  case "$_p" in $_ge) return 0;; esac',
                     '  done; return 1; }',
                    // startup scan: handle pkg already running when daemon starts
                    '_ae && { resetprop debug.hwui.renderer skiagl 2>/dev/null || true;',
                    '  printf "1\\n" > "$_SF" 2>/dev/null || true;',
                    '  printf "[ADRENO][DAEMON] startup:excl running->skiagl\\n" > /dev/kmsg 2>/dev/null || true; }',
                    // event-driven loop: outer while restarts logcat if it ever exits
                    'while true; do',
                    '  logcat -b events -v tag am_proc_start:I am_proc_died:I 2>/dev/null |',
                    '  while IFS= read -r _ln; do',
                     '    _ga=$(cat "$_SF" 2>/dev/null || printf 0)',
                     // FIX: extract _fb (raw fields) here; extract _pkg per-branch.
                     // am_proc_start: [userId,pid,uid,processName,type,component] f4=pkg
                     // am_proc_died:  [userId,pid,processName,adj,procState]      f3=pkg
                     // Prior shared cut -d,-f4 for both events = BUG: am_proc_died f4 is
                     // the adj integer (e.g. '18'), not the package name. _ie('18') never
                     // matched, so _SF was never reset to 0 after app exit. Next open:
                     // _ga=1 -> continue -> entire am_proc_start event SKIPPED -> no switch.
                     '    _f="${_ln#*[}"; _fb="${_f%%]*}"',
                     '    case "$_ln" in',
                     '      *am_proc_start*)',
                     '        _pkg=$(printf "%s" "$_fb" | cut -d, -f4 | tr -d " ")',
                     '        [ -n "$_pkg" ] || continue',
                     '        [ "$_ga" = 1 ] && continue',
                     '        _ie "$_pkg" || continue',
                     '        _ae || continue',  // verify live (guards stale logcat buffer entries)
                     '        resetprop debug.hwui.renderer skiagl 2>/dev/null || true',
                     '        printf "1\\n" > "$_SF" 2>/dev/null || true',
                     '        printf "[ADRENO][DAEMON] start:%s->skiagl\\n" "$_pkg" > /dev/kmsg 2>/dev/null || true',
                     '        ;;',
                     '      *am_proc_died*)',
                     '        _pkg=$(printf "%s" "$_fb" | cut -d, -f3 | tr -d " ")',
                     '        [ -n "$_pkg" ] || continue',
                     '        [ "$_ga" = 0 ] && continue',
                     '        _ie "$_pkg" || continue',
                     '        _ae && continue',  // other excluded pkgs still running
                     '        resetprop debug.hwui.renderer "$_RESTORE" 2>/dev/null || true',
                     '        printf "0\\n" > "$_SF" 2>/dev/null || true',
                     '        printf "[ADRENO][DAEMON] died:%s->%s\\n" "$_pkg" "$_RESTORE" > /dev/kmsg 2>/dev/null || true',
                     '        ;;',
                     '    esac',
                     '  done',
                     '  sleep 2',  // logcat exited (OEM quirk) -- restart
                     'done',
                ];

                // Write shebang → create/truncate file
                await exec(`printf '%s\\n' '${scriptLines[0]}' > '${daemonPath}' 2>/dev/null`);
                // Write GAME_EXCLUSION_PKGS with JS interpolation
                await exec(`printf 'GAME_EXCLUSION_PKGS="%s"\\n' '${exclPkgs}' >> '${daemonPath}' 2>/dev/null`);
                // Write body: single printf call, all lines single-quoted
                const body = scriptLines.slice(2).map(l => `'${l}'`).join(' ');
                await exec(`printf '%s\\n' ${body} >> '${daemonPath}' 2>/dev/null`);

                await exec(`chmod 755 '${daemonPath}' 2>/dev/null; true`);
                await exec(`nohup sh '${daemonPath}' >/dev/null 2>&1 &`);

                logToTerminal(`✅ Event daemon respawned — ${_gameExclPkgs.length} pkgs monitored (logcat am_proc_start/died, skiagl↔${renderMode})`, 'success');
            } catch (daemonErr) {
                // Non-fatal — renderer props are already live. Daemon is best-effort.
                logToTerminal(`⚠️ Daemon respawn failed (non-fatal): ${daemonErr}`, 'warn');
            }
        }

        await loadRenderStatus();
        showToast(`✅ Render mode applied: ${renderMode}`);
    } catch (e) {
        logToTerminal('applyRenderNow error: ' + (e.message || e), 'error');
        showToast('❌ Failed to apply render mode');
    } finally {
        setLoading(false);
    }
}

async function saveConfig() {
    const confirmed = await ConfirmDialog.show(
        currentTranslations.save || 'Save Configuration',
        currentTranslations.saveRebootInfo || 'Changes require reboot to take effect.',
        '💾'
    );
    
    if (!confirmed) return;
    
    setLoading(true);
    logToTerminal('Saving configuration...', 'info');

    try {

    const getValue = (id) => {
        const el = document.getElementById(id);
        if (!el) return '';
        return el.type === 'checkbox' ? (el.checked ? 'y' : 'n') : el.value;
    };
    
    // Validate RENDER_MODE
    const renderMode2 = getValue('RENDER_MODE');
    const validModes = ['normal', 'skiavk', 'skiagl', 'skiavk_all'];
    const finalRenderMode = validModes.includes(renderMode2) ? renderMode2 : 'normal';
    if (!validModes.includes(renderMode2)) {
        showToast('⚠️ Invalid render mode, using default');
        logToTerminal(`Invalid RENDER_MODE: ${renderMode2}, defaulting to normal`, 'warn');
        const renderSelect = document.getElementById('RENDER_MODE');
        if (renderSelect) renderSelect.value = 'normal';
    }

    const plt           = getValue('PLT');
    const qgl           = getValue('QGL');
    const arm           = getValue('ARM64_OPT');
    const verbose       = getValue('VERBOSE');
    const daemon        = getValue('GAME_EXCLUSION_DAEMON');
    const forceThreaded = getValue('FORCE_SKIAVKTHREADED_BACKEND');
    const theme         = currentTheme || 'purple';

    const writeConfig = (path) =>
        exec(`printf 'PLT=%s\\nQGL=%s\\nARM64_OPT=%s\\nVERBOSE=%s\\nRENDER_MODE=%s\\nGAME_EXCLUSION_DAEMON=%s\\nFORCE_SKIAVKTHREADED_BACKEND=%s\\nTHEME=%s\\n' '${plt}' '${qgl}' '${arm}' '${verbose}' '${finalRenderMode}' '${daemon}' '${forceThreaded}' '${theme}' > "${path}" 2>/dev/null`);

    await writeConfig(`${SD_CONFIG}/adreno_config.txt`);
    await writeConfig(`${MOD_PATH}/adreno_config.txt`);

    // Write render mode + all stability props to system.prop for boot persistence
    if (MOD_PATH) {
        const sysprPath = `${MOD_PATH}/system.prop`;
        // Build the strip pattern inline — previously referenced an undefined variable
        // "STRIP" which caused awk to receive '!/^(undefined)/' so old props were NEVER
        // removed from system.prop. Fixed: build the pattern locally here.
        const _SAVE_CLEAR = [
            'debug.hwui.renderer','debug.renderengine.backend',
            'debug.sf.latch_unsignaled','debug.sf.auto_latch_unsignaled',
            'debug.sf.disable_backpressure','debug.sf.enable_hwc_vds',
            'ro.sf.disable_triple_buffer','debug.sf.client_composition_cache_size',
            'debug.sf.enable_transaction_tracing','ro.surface_flinger.use_context_priority',
            'ro.surface_flinger.max_frame_buffer_acquired_buffers',
            'ro.surface_flinger.force_hwc_copy_for_virtual_displays',
            'com.qc.hardware','persist.sys.force_sw_gles',
            'debug.hwui.use_buffer_age','debug.hwui.use_partial_updates',
            'debug.hwui.use_gpu_pixel_buffers','renderthread.skia.reduceopstasksplitting',
            'debug.hwui.skip_empty_damage','debug.hwui.webview_overlays_enabled',
            'debug.hwui.skia_tracing_enabled','debug.hwui.skia_use_perfetto_track_events',
            'debug.hwui.capture_skp_enabled','debug.hwui.skia_atrace_enabled',
            'debug.hwui.use_hint_manager','debug.hwui.target_cpu_time_percent',
            'debug.vulkan.layers','ro.hwui.use_vulkan',
            'debug.hwui.recycled_buffer_cache_size',
            'debug.hwui.overdraw','debug.hwui.profile',
            'debug.hwui.show_dirty_regions','graphics.gpu.profiler.support',
            'ro.egl.blobcache.multifile','ro.egl.blobcache.multifile_limit',
            'debug.hwui.render_thread','debug.hwui.render_dirty_regions',
            'debug.hwui.show_layers_updates','debug.hwui.filter_test_overhead',
            'debug.hwui.nv_profiling','debug.hwui.clip_surfaceviews',
            'debug.hwui.8bit_hdr_headroom','debug.hwui.skip_eglmanager_telemetry',
            'debug.hwui.initialize_gl_always','debug.hwui.level','debug.hwui.disable_vsync',
            'persist.device_config.runtime_native.usap_pool_enabled',
            'debug.gralloc.enable_fb_ubwc','vendor.gralloc.enable_fb_ubwc',
            'persist.sys.perf.topAppRenderThreadBoost.enable',
            'persist.sys.gpu.working_thread_priority',
            'debug.sf.early_phase_offset_ns','debug.sf.early_app_phase_offset_ns',
            'debug.sf.early_gl_phase_offset_ns','debug.sf.early_gl_app_phase_offset_ns',
            'debug.hwui.use_skia_graphite','ro.surface_flinger.supports_background_blur',
            'persist.sys.sf.disable_blurs','ro.sf.blurs_are_expensive',
            'hwui.disable_vsync','debug.vulkan.layers.enable',
            'debug.hwui.texture_cache_size','debug.hwui.layer_cache_size',
            'debug.hwui.path_cache_size','debug.sf.use_phase_offsets_as_durations',
            'ro.config.vulkan.enabled','persist.vendor.vulkan.enable',
            'persist.graphics.vulkan.disable_pre_rotation',
            'debug.hwui.force_dark','debug.sf.treat_170m_as_sRGB',
            'ro.hwui.text_small_cache_width','ro.hwui.text_small_cache_height',
            'ro.hwui.text_large_cache_width','ro.hwui.text_large_cache_height',
            'ro.hwui.drop_shadow_cache_size','ro.hwui.gradient_cache_size',
            'persist.sys.sf.native_mode','debug.egl.debug_proc',
            'debug.sf.hw','persist.sys.ui.hw','debug.egl.hw',
            'debug.egl.profiler','debug.egl.trace',
            'debug.vulkan.dev.layers','persist.graphics.vulkan.validation_enable',
            'debug.hwui.drawing_enabled',
        ];
        // Build strip pattern: each item escaped for ERE dot-matching.
        // NO leading ^ per item — the outer awk pattern already has !/^(...)/ which
        // anchors the alternation to the start of line. Adding ^ inside each alternative
        // creates !/^(^A=|^B=)/ which fails on Android busybox/toybox awk implementations
        // that treat ^ after | inside a group as a literal character rather than a line anchor.
        // Result: old props were NEVER stripped from system.prop, accumulating across mode
        // switches (skiavk props left behind when switching to skiagl → crash).
        const STRIP = _SAVE_CLEAR.map(p => `${p.replace(/\./g, '\\\\.')}=`).join('|');
        await exec(`[ -f "${sysprPath}" ] || touch "${sysprPath}"`);
        await exec(`awk '!/^(${STRIP})/' "${sysprPath}" > "${sysprPath}.tmp" && mv "${sysprPath}.tmp" "${sysprPath}" 2>/dev/null || true`);
        if (finalRenderMode === 'skiavk' || finalRenderMode === 'skiavk_all') {
            // ── UPDATED STRATEGY: write renderer props to system.prop ────────────────
            // Module system.prop is applied by root manager (Magisk/KSU/APatch) via resetprop
            // AFTER magic-mount completes — Vulkan driver overlay is already in place.
            // Writing debug.hwui.renderer=skiavk to system.prop (renderengine.backend excluded — OEM watcher bootloop fix)
            // here ensures both HWUI and SurfaceFlinger initialize correctly from the very
            // first process on next boot, including SystemUI, without resetprop timing races.
            const lines = [
                // ── Renderer props ──
                // debug.hwui.renderer persisted here — per-process HWUI prop, safe.
                // debug.renderengine.backend excluded — OEM SF watcher bootloop risk.
                'debug.hwui.renderer=skiavk',
                // ── DANGEROUS SF PROPS INTENTIONALLY OMITTED ─────────────────────────
                // (latch_unsignaled, disable_backpressure, disable_triple_buffer, etc.)
                // See _ALL_SKIAVK_PROPS comment in applyRenderNow() for root cause.
                // These remain in STRIP constants so they get cleaned up from older versions.
                // ── SF phase offsets INTENTIONALLY OMITTED ───────────────────────────
                // SM8150-specific workarounds — cause vsync starvation reboot loops on
                // Adreno 6xx/7xx at 90/120Hz. Device trees provide correct values.
                // (debug.sf.use_phase_offsets_as_durations — also EXCLUDED: Samsung-only)
                // ── Qualcomm / OEM gates ────────────────────────────────────────────────
                'com.qc.hardware=true',
                'persist.sys.force_sw_gles=0',
                // ── HWUI Skia Vulkan stability ─────────────────────────────────────────
                'debug.hwui.use_buffer_age=false',
                'debug.hwui.use_partial_updates=false',
                'debug.hwui.use_gpu_pixel_buffers=false',
                // reduceopstasksplitting=false — AOSP default; true causes rendering artifacts
                'renderthread.skia.reduceopstasksplitting=false',
                'debug.hwui.skip_empty_damage=true',
                'debug.hwui.webview_overlays_enabled=true',
                'debug.hwui.skia_tracing_enabled=false',
                'debug.hwui.skia_use_perfetto_track_events=false',
                'debug.hwui.capture_skp_enabled=false',
                'debug.hwui.skia_atrace_enabled=false',
                'debug.hwui.use_hint_manager=true',
                'debug.hwui.target_cpu_time_percent=33',
                // ── OEM / legacy ROM compat ────────────────────────────────────────────
                'debug.vulkan.layers=',
                'ro.hwui.use_vulkan=true',
                'debug.hwui.recycled_buffer_cache_size=4',
                'debug.hwui.overdraw=false',
                'debug.hwui.profile=false',
                'debug.hwui.show_dirty_regions=false',
                'graphics.gpu.profiler.support=false',
                // ── EGL shader blob cache ─────────────────────────────────────────────
                'ro.egl.blobcache.multifile=true',
                'ro.egl.blobcache.multifile_limit=33554432',
                // ── HWUI debug overhead elimination ───────────────────────────────────
                'debug.hwui.render_thread=true',
                'debug.hwui.render_dirty_regions=false',
                'debug.hwui.show_layers_updates=false',
                'debug.hwui.filter_test_overhead=false',
                'debug.hwui.nv_profiling=false',
                // debug.hwui.clip_surfaceviews: NOT written. AOSP default (true) correct.
                // Writing false causes SurfaceView (video/camera) to bleed outside bounds.
                'debug.hwui.8bit_hdr_headroom=false',
                'debug.hwui.skip_eglmanager_telemetry=true',
                // initialize_gl_always=false — do NOT pre-load GL at Zygote when Vulkan active
                // true loads both drivers → ~20MB extra RAM per process → OOM on heavy apps
                'debug.hwui.initialize_gl_always=false',
                'debug.hwui.level=0',
                'debug.hwui.disable_vsync=false',
                // ── System performance ────────────────────────────────────────────────
                'persist.device_config.runtime_native.usap_pool_enabled=true',
                'debug.gralloc.enable_fb_ubwc=1',
                'persist.sys.perf.topAppRenderThreadBoost.enable=true',
                'persist.sys.gpu.working_thread_priority=1',
                // ── Disable problematic features ─────────────────────────────────────
                'debug.hwui.use_skia_graphite=false',
                // blur: NOT disabled — breaks Samsung/MIUI WindowBlurBehind in SkiaVK
                'ro.sf.blurs_are_expensive=1',
                'vendor.gralloc.enable_fb_ubwc=1',
                // ── Samsung/MIUI/Qualcomm Vulkan compat gates ─────────────────────────
                'ro.config.vulkan.enabled=true',
                'persist.vendor.vulkan.enable=1',
                // disable_pre_rotation: NOT SET — causes VK_ERROR_OUT_OF_DATE_KHR crash in UE4/Unity
                'debug.hwui.force_dark=false',
                // ── Text atlas: AOSP defaults restored ───────────────────────────────
                // Reduction caused glyph cache overflow → font corruption → HWUI crash
                'ro.hwui.text_small_cache_width=1024',
                'ro.hwui.text_small_cache_height=512',
                'ro.hwui.text_large_cache_width=2048',
                'ro.hwui.text_large_cache_height=1024',
                'ro.hwui.drop_shadow_cache_size=3',
                'ro.hwui.gradient_cache_size=1',
                // native_mode: NOT SET — disables HDR/WCG on capable displays
                // Samsung/Xiaomi WCG: map BT.601/170M → VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
                'debug.sf.treat_170m_as_sRGB=1',
                // Clear OEM EGL debug hook (MIUI/HyperOS/ColorOS ABI mismatch → SIGSEGV)
                'debug.egl.debug_proc=',
                // ── Always-active HW path reinforcement ──────────────────────────────
                'debug.sf.hw=1',
                'persist.sys.ui.hw=1',
                'debug.egl.hw=1',
                'debug.egl.profiler=0',
                'debug.egl.trace=0',
                // OEM Vulkan dev/validation layer clearing
                'debug.vulkan.dev.layers=',
                'persist.graphics.vulkan.validation_enable=0',
                // HWUI drawing enforcement + vsync clear
                'debug.hwui.drawing_enabled=true',
                'hwui.disable_vsync=false',
            ].join('\\n');
            await exec(`printf '${lines}\\n' >> "${sysprPath}"`);
            logToTerminal(`✓ system.prop: skiavk props written — hwui.renderer=skiavk + HWUI+OEM+EGL+perf+compat+VKfix props. renderengine.backend excluded (OEM SF watcher bootloop fix). Phase offsets OMITTED. Dangerous SF fence/buffer props EXCLUDED.`, 'success');
        } else if (finalRenderMode === 'skiagl') {
            // Write full skiagl prop set to system.prop — synced with post-fs-data.sh
            const _SKIAGL_SAVE = [
                'debug.hwui.renderer=skiagl',
                // debug.renderengine.backend excluded — OEM SF watcher bootloop risk.
                'persist.sys.force_sw_gles=0',
                'com.qc.hardware=true',
                // Partial updates disabled — EGL extensions unreliable on custom Adreno drivers
                'debug.hwui.use_buffer_age=false',
                'debug.hwui.use_partial_updates=false',
                'debug.hwui.render_dirty_regions=false',
                'debug.hwui.webview_overlays_enabled=true',
                // reduceopstasksplitting=false — AOSP default; true causes rendering artifacts
                'renderthread.skia.reduceopstasksplitting=false',
                'debug.hwui.skia_tracing_enabled=false',
                'debug.hwui.skia_use_perfetto_track_events=false',
                'debug.hwui.capture_skp_enabled=false',
                'debug.hwui.skia_atrace_enabled=false',
                'debug.hwui.overdraw=false',
                'debug.hwui.profile=false',
                'debug.hwui.show_dirty_regions=false',
                'debug.hwui.show_layers_updates=false',
                'ro.egl.blobcache.multifile=true',
                'ro.egl.blobcache.multifile_limit=33554432',
                'debug.hwui.render_thread=true',
                'debug.hwui.use_hint_manager=true',
                'debug.hwui.target_cpu_time_percent=66',
                'debug.hwui.skip_eglmanager_telemetry=true',
                // initialize_gl_always=false — CRASH FIX: see applyRenderNow _SKIAGL_PROPS comment.
                'debug.hwui.initialize_gl_always=false',
                'debug.hwui.disable_vsync=false',
                'debug.hwui.level=0',
                'debug.gralloc.enable_fb_ubwc=1',
                'vendor.gralloc.enable_fb_ubwc=1',
                'persist.device_config.runtime_native.usap_pool_enabled=true',
                'persist.sys.perf.topAppRenderThreadBoost.enable=true',
                'persist.sys.gpu.working_thread_priority=1',
                'debug.hwui.use_skia_graphite=false',
                // blur: ENABLED in GL mode — GL blur uses standard EGL paths, works correctly
                'ro.sf.blurs_are_expensive=1',
                // HW path enforcement + OEM layer clearing + drawing state
                'debug.sf.hw=1',
                'persist.sys.ui.hw=1',
                'debug.egl.hw=1',
                'debug.egl.profiler=0',
                'debug.egl.trace=0',
                'debug.vulkan.dev.layers=',
                'persist.graphics.vulkan.validation_enable=0',
                'debug.hwui.drawing_enabled=true',
                'hwui.disable_vsync=false',
                'debug.egl.debug_proc=',
                'debug.hwui.force_dark=false',
                // ── 7 crash-fix props (see applyRenderNow _SKIAGL_PROPS for full root-cause comments) ─
                // Snapdragon Profiler GL intercept crash (OEM default often true)
                'graphics.gpu.profiler.support=false',
                // PBO async readback race → SIGSEGV on screenshots/multitasking
                'debug.hwui.use_gpu_pixel_buffers=false',
                // Buffer cache: AOSP default 4 (OEM 0 causes constant realloc → OOM)
                'debug.hwui.recycled_buffer_cache_size=4',
                // Skip GPU work for unchanged regions
                'debug.hwui.skip_empty_damage=true',
                // Per-draw-call overhead measurement → CPU stalls between GL calls
                'debug.hwui.filter_test_overhead=false',
                // Incompatible profiling callback → SIGSEGV on shader compile
                'debug.hwui.nv_profiling=false',
                // HDR headroom tone-map shader not supported by custom Adreno → GPU fault
                'debug.hwui.8bit_hdr_headroom=false',
            ];
            await exec(`printf '${_SKIAGL_SAVE.join('\\n')}\\n' >> "${sysprPath}"`);
            logToTerminal(`✓ system.prop: ${_SKIAGL_SAVE.length} skiagl+renderengine+stability+perf+compat props written`, 'success');
        } else {
            logToTerminal('✓ system.prop: render props cleared (normal mode)', 'success');
        }
    }

    // Update statistics
    incrementStat('configChanges');

    // Clear stale Skia pipeline caches on render mode save.
    // When user hits "Save and Reboot", on next boot post-fs-data.sh sets the new
    // renderer via resetprop. Apps then cold-start with the new renderer but may
    // still have old-format pipeline caches (GL format when switching to skiavk).
    // Pre-clearing them here prevents the "apps crash immediately on open" symptom
    // on the first boot after a mode change, even if "Apply Now" was not used.
    if (finalRenderMode !== 'normal') {
        // Pre-clear per-app pipeline caches so first boot after reboot won't crash on renderer switch.
        // /data/misc/hwui/ is intentionally NOT deleted here — SF has it open while running and the
        // boot scripts (post-fs-data.sh line ~1109) already clear it at boot before SF starts.
        // Deleting it while SF is active causes write errors on SF's pipeline cache serialize path.
        // Per-app app_skia_pipeline_cache dirs are safe to delete here: Linux VFS inode refcounting
        // keeps existing fds valid; apps handle missing cache dirs gracefully (Skia regenerates them).
        logToTerminal('⏳ Pre-clearing per-app Skia pipeline caches for renderer switch...', 'info');
        await exec('find /data/user_de/0 -maxdepth 2 -type d -name "app_skia_pipeline_cache" -exec rm -rf {} + 2>/dev/null; true');
        await exec('find /data/data -maxdepth 2 -type d -name "app_skia_pipeline_cache" -exec rm -rf {} + 2>/dev/null; true');
        await exec('find /data/user_de/0 -maxdepth 2 -name "*.shader_journal" -delete 2>/dev/null; true');
        logToTerminal('✅ Per-app Skia pipeline caches pre-cleared — boot scripts clear /data/misc/hwui/ at boot time', 'success');
    }

    showToast(currentTranslations.msgConfigSaved || '✅ Configuration saved!');
    logToTerminal('✓ Configuration saved successfully', 'success');
    
    UIManager.showBanner(
        `${currentTranslations.msgConfigSaved || 'Configuration saved'}\n\n⚠️ ${currentTranslations.saveRebootInfo || 'Reboot required for changes to take effect.'}`,
        'success'
    );

    } catch (e) {
        const msg = e && e.message ? e.message : String(e);
        logToTerminal('saveConfig error: ' + msg, 'error');
        showToast('❌ Failed to save configuration');
    } finally {
        setLoading(false);
    }
}

async function openQGLEditor() {
    const modal = document.getElementById('qglModal');
    if (!modal) return;
    
    setLoading(true);
    logToTerminal('Opening QGL Editor...', 'info');

    try {
        // Try module path first, then SD card (same as old working version)
        let res = await exec(`cat "${MOD_PATH}/qgl_config.txt" 2>/dev/null`);
        if (res.errno !== 0) {
            res = await exec(`cat "${SD_CONFIG}/qgl_config.txt" 2>/dev/null`);
        }
        
        // Only check errno, not stdout (stdout can be empty string which is valid)
        const content = res.errno === 0 ? res.stdout : '# QGL Configuration\n# Add your keys here\n';
        
        const editor = document.getElementById('qglEditor');
        if (editor) {
            editor.value = content;
            updateQGLLineCount();
            logToTerminal(`✓ QGL Config loaded (${content.split('\n').length} lines)`, 'success');
        }
        
        modal.style.display = 'block';
    } catch (e) {
        logToTerminal('openQGLEditor error: ' + (e && e.message ? e.message : String(e)), 'error');
        showToast('❌ Failed to open QGL editor');
    } finally {
        setLoading(false);
    }
}

async function saveQGL() {
    const editor = document.getElementById('qglEditor');
    if (!editor) return;

    setLoading(true);
    const content = editor.value || '';
    // escape single quotes for safe shell usage
    const safeContent = content.replace(/'/g, "'\\''");

    logToTerminal('Saving QGL Config...', 'info');

    // Paths (leave these names as-is if your globals use them)
    const defaultBak = `${SD_ROOT}/default.txt.bak`;   // persistent default backup in Adreno folder
    const userSave   = `${SD_ROOT}/qgl_config.txt`;    // user's edited copy in Adreno folder
    const moduleFile = `${MOD_PATH}/qgl_config.txt`;   // module's qgl file
    const sdConfigFile = `${SD_CONFIG}/qgl_config.txt`; // fallback SD config

    try {
        // --- 1) Create default.txt.bak only if it does NOT already exist ---
        const bakCheck = await exec(`[ -f "${defaultBak}" ] && echo "exists" || echo "missing"`);
        const bakExists = bakCheck && bakCheck.stdout && bakCheck.stdout.includes('exists');

        if (!bakExists) {
            // Try to copy from module, else from SD config, else create an empty default bak
            await exec(
                `cp "${moduleFile}" "${defaultBak}" 2>/dev/null || cp "${sdConfigFile}" "${defaultBak}" 2>/dev/null || printf '%s' '' > "${defaultBak}"`
            );
            logToTerminal(`default backup created at ${defaultBak}`, 'info');
        } else {
            logToTerminal(`default.txt.bak already exists at ${defaultBak} — will not overwrite.`, 'info');
        }

        // --- 2) Save the user's edited copy into the Adreno folder (userSave) ---
        await exec(`printf '%s' '${safeContent}' > "${userSave}"`);
        logToTerminal(`User QGL saved to Adreno folder: ${userSave}`, 'success');

        // --- 3) Copy user's saved file into the module (overwrite module config) ---
        // Prefer cp; if cp can't write, fallback to printf into module path
        await exec(`cp "${userSave}" "${moduleFile}" 2>/dev/null || printf '%s' '${safeContent}' > "${moduleFile}"`);
        logToTerminal(`Module QGL updated: ${moduleFile}`, 'success');

        // update app stats (if function exists)
        if (typeof incrementStat === 'function') incrementStat('configChanges');

        showToast(currentTranslations?.msgQGLSaved || '✅ QGL Config Saved (Persistent)');
    } catch (err) {
        const msg = err && err.message ? err.message : String(err);
        logToTerminal('saveQGL error: ' + msg, 'error');
        showToast(currentTranslations?.msgQGLFail || '❌ Failed to save QGL Config');
    } finally {
        setLoading(false);
    }
}

function updateQGLLineCount() {
    const editor = document.getElementById('qglEditor');
    const counter = document.getElementById('qglLineCount');
    if (editor && counter) {
        counter.textContent = (editor.value.match(/\n/g) || []).length + 1;
    }
}

// ============================================
// GPU SPOOFER - DYNAMIC ROBUST IMPLEMENTATION
// No hardcoded model lists - fully future-proof
// ============================================

async function scanGpuModels() {
    const select = document.getElementById('spoofSourceSelect');
    if (!select) return;
    
    logToTerminal('Scanning GPU models from libgsl.so...', 'info');
    
    // Find all libgsl.so files in module system/vendor
    const findRes = await exec(`find "${MOD_PATH}/system/vendor" -name "libgsl.so" 2>/dev/null`);
    if (findRes.errno !== 0 || !findRes.stdout || !findRes.stdout.trim()) {
        select.innerHTML = '<option value="" disabled>No libgsl.so found</option>';
        logToTerminal("Spoofer: No libgsl.so files found in module.", 'warn');
        return;
    }

    const files = findRes.stdout.trim().split('\n');
    logToTerminal(`Spoofer: Found ${files.length} libgsl.so file(s).`, 'info');
    
    // DYNAMIC MULTI-METHOD EXTRACTION
    // Each method extracts whatever models exist - no hardcoded lists
    let allModels = new Set();
    
    for (const file of files) {
        logToTerminal(`Analyzing: ${file}`, 'info');
        
        // ═══════════════════════════════════════════════════════
        // METHOD 1: strings + grep (Best for binary files)
        // Dynamically finds ANY "Adreno (TM) XXX" or "Adreno (TM) XXXX" pattern
        // Works for 3-digit (730) and 4-digit (750, 7300) models
        // ═══════════════════════════════════════════════════════
        const stringsRes = await exec(`strings "${file}" 2>/dev/null | grep -oE "Adreno \\(TM\\) [0-9]{3,4}" | grep -oE "[0-9]{3,4}" | sort -u`);
        const sizeBeforeM1 = allModels.size;
        if (stringsRes.errno === 0 && stringsRes.stdout && stringsRes.stdout.trim()) {
            const models = stringsRes.stdout.trim().split('\n');
            models.forEach(m => {
                const trimmed = m.trim();
                if (trimmed && /^\d{3,4}$/.test(trimmed)) {
                    allModels.add(trimmed);
                }
            });
        }
        
        // Methods 2-4 are variations of method 1 — skip if method 1 already found models
        const foundInM1 = allModels.size > sizeBeforeM1;
        
        if (!foundInM1) {
        // ═══════════════════════════════════════════════════════
        // METHOD 2: Original grep pattern 
        // Dynamically finds 3-digit models
        // ═══════════════════════════════════════════════════════
        const originalRes = await exec(`grep -ao "Adreno (TM) [0-9][0-9][0-9]" "${file}" 2>/dev/null | cut -d ' ' -f 3 | sort -u`);
        if (originalRes.errno === 0 && originalRes.stdout && originalRes.stdout.trim()) {
            const models = originalRes.stdout.trim().split('\n');
            models.forEach(m => {
                const trimmed = m.trim();
                if (trimmed && /^\d{3}$/.test(trimmed)) {
                    allModels.add(trimmed);
                }
            });
        }
        
        // ═══════════════════════════════════════════════════════
        // METHOD 3: Extended grep for 3-4 digit patterns
        // Dynamically finds both 3-digit and 4-digit models
        // ═══════════════════════════════════════════════════════
        const extendedRes = await exec(`grep -aoE "Adreno \\(TM\\) [0-9]{3,4}" "${file}" 2>/dev/null | grep -oE "[0-9]{3,4}" | sort -u`);
        if (extendedRes.errno === 0 && extendedRes.stdout && extendedRes.stdout.trim()) {
            const models = extendedRes.stdout.trim().split('\n');
            models.forEach(m => {
                const trimmed = m.trim();
                if (trimmed && /^\d{3,4}$/.test(trimmed)) {
                    allModels.add(trimmed);
                }
            });
        }
        
        // ═══════════════════════════════════════════════════════
        // METHOD 4: Case-insensitive flexible pattern matching
        // Handles potential variations in spacing or formatting
        // Dynamically captures whatever pattern exists
        // ═══════════════════════════════════════════════════════
        const flexibleRes = await exec(`strings "${file}" 2>/dev/null | grep -ioE "adreno.{0,5}\\(tm\\).{0,5}[0-9]{3,4}" | grep -oE "[0-9]{3,4}" | sort -u`);
        if (flexibleRes.errno === 0 && flexibleRes.stdout && flexibleRes.stdout.trim()) {
            const models = flexibleRes.stdout.trim().split('\n');
            models.forEach(m => {
                const trimmed = m.trim();
                if (trimmed && /^\d{3,4}$/.test(trimmed)) {
                    allModels.add(trimmed);
                }
            });
        }
        } // end !foundInM1 block
        
        // ═══════════════════════════════════════════════════════
        // METHOD 5: Raw binary grep with both text representations
        // Some binaries store the string without the (TM) marker
        // Dynamically searches for "Adreno XXX" patterns too
        // ═══════════════════════════════════════════════════════
        const rawRes = await exec(`strings "${file}" 2>/dev/null | grep -oE "Adreno [0-9]{3,4}" | grep -oE "[0-9]{3,4}" | sort -u`);
        if (rawRes.errno === 0 && rawRes.stdout && rawRes.stdout.trim()) {
            const models = rawRes.stdout.trim().split('\n');
            models.forEach(m => {
                const trimmed = m.trim();
                // Additional validation: only add if it's a realistic Adreno model number
                // Adreno models typically start with 2, 3, 4, 5, 6, 7, 8, 9 (not 0, 1)
                if (trimmed && /^\d{3,4}$/.test(trimmed) && parseInt(trimmed) >= 200) {
                    allModels.add(trimmed);
                }
            });
        }
    }

    // Sort models numerically for proper ordering (605, 610, 630, 650, 710, 730, 750, etc.)
    const sortedModels = Array.from(allModels).sort((a, b) => parseInt(a) - parseInt(b));
    
    if (sortedModels.length === 0) {
        select.innerHTML = '<option value="" disabled>No models found</option>';
        logToTerminal("Spoofer: No Adreno models detected in binaries.", 'warn');
        return;
    }

    select.innerHTML = '<option value="" disabled selected>Select Model</option>';
    sortedModels.forEach(m => {
        const opt = document.createElement('option');
        opt.value = m;
        opt.textContent = m;
        select.appendChild(opt);
    });
    logToTerminal(`Spoofer: Detected models: ${sortedModels.join(', ')}`, 'success');
    logToTerminal(`Total unique models found: ${sortedModels.length}`, 'success');
}

async function applyGpuSpoof() {
    const source = document.getElementById('spoofSourceSelect')?.value;
    const target = document.getElementById('spoofTargetInput')?.value;

    if (!source || !target) {
        showToast("Please select source and enter target model.");
        return;
    }

    // Accept both 3-digit and 4-digit models
    if (!/^\d{3,4}$/.test(target)) {
        showToast("Target model must be 3 or 4 digits (e.g. 730, 750, 7300).");
        return;
    }

    // CRITICAL SAFETY CHECK: Source and target MUST be the same digit length.
    // libgsl.so is an ELF binary. sed -i replaces bytes in-place.
    // If "Adreno (TM) 730" (15 chars) is replaced with "Adreno (TM) 7300" (16 chars),
    // the file size changes → the ELF binary is CORRUPTED → BOOTLOOP on next boot.
    if (source.length !== target.length) {
        showToast(`⚠️ Source (${source}) and target (${target}) must have the same digit count to avoid ELF corruption and bootloop!`);
        logToTerminal(`SAFETY BLOCK: Mismatched digit lengths (${source.length} vs ${target.length}) would corrupt ELF binary and cause bootloop.`, 'error');
        return;
    }

    setLoading(true);
    logToTerminal(`Spoofer: Starting spoof ${source} -> ${target}`, 'info');

    const findRes = await exec(`find "${MOD_PATH}/system/vendor" -name "libgsl.so" 2>/dev/null`);
    if (findRes.errno !== 0 || !findRes.stdout || !findRes.stdout.trim()) {
        setLoading(false);
        showToast("Error: libgsl.so not found.");
        return;
    }

    const files = findRes.stdout.trim().split('\n');
    let successCount = 0;
    let totalPatches = 0;
    let filesProcessed = 0;

    const SD_BACKUP = `${SD_ROOT}/Backup`;
    // Ensure backup subdirectories exist for lib and lib64 separately.
    // CRITICAL: Never place backups inside module/system - Magisk/KernelSU will
    // overlay them into the live /vendor/ filesystem causing SELinux/bootloop issues.
    await exec(`mkdir -p "${SD_BACKUP}/lib" "${SD_BACKUP}/lib64" 2>/dev/null`);

    for (const file of files) {
        filesProcessed++;
        logToTerminal(`[${filesProcessed}/${files.length}] Processing: ${file}`, 'info');
        
        // SECURITY: Strict validation for both 3 and 4 digit models 
        if (!/^\d{3,4}$/.test(source) || !/^\d{3,4}$/.test(target)) {
            logToTerminal(`Security error: Invalid characters detected`, 'error');
            continue;
        }
        
        // 1. Backup original file to SD card (NOT inside module system dir!)
        // CRITICAL FIX: If we place .bak inside ${MOD_PATH}/system/vendor/...,
        // Magisk/KernelSU will overlay that .bak file into the live /vendor/ system.
        // SELinux, OEM integrity scanners, and dm-verity can then BOOTLOOP the device.
        // Solution: Store backups in /sdcard/Adreno_Driver/Backup/lib/ or /lib64/.
        //
        // BACKUP STRUCTURE (mirrors the real library layout):
        //   /sdcard/Adreno_Driver/Backup/lib/libgsl.so   ← from system/vendor/lib/
        //   /sdcard/Adreno_Driver/Backup/lib64/libgsl.so ← from system/vendor/lib64/
        //
        // FIRST-BACKUP-WINS RULE: Once a backup exists for a given variant (lib or lib64),
        // it is NEVER overwritten by subsequent spoofs. This preserves the true original
        // so the "Restore Original" button always restores the factory-stock binary.
        const fileName = file.split('/').pop(); // "libgsl.so"
        // Determine which lib variant this file belongs to based on its full path
        const libSubdir = file.includes('/lib64/') ? 'lib64' : 'lib';
        const safeBackupPath = `${SD_BACKUP}/${libSubdir}/${fileName}`;
        // Only create backup if one doesn't already exist for this lib variant
        const existingBakCheck = await exec(`[ -f "${safeBackupPath}" ] && echo "exists" || echo "missing"`);
        const bakAlreadyExists = existingBakCheck && existingBakCheck.stdout && existingBakCheck.stdout.includes('exists');
        if (!bakAlreadyExists) {
            const backupRes = await exec(`cp "${file}" "${safeBackupPath}" 2>/dev/null`);
            if (backupRes.errno === 0) {
                logToTerminal(`  Backup created: ${safeBackupPath}`, 'info');
            } else {
                logToTerminal(`  Warning: Could not create backup at ${safeBackupPath}`, 'warn');
            }
        } else {
            logToTerminal(`  Backup already exists: ${safeBackupPath} (original preserved)`, 'info');
        }
        
        // 2. Count occurrences BEFORE patching 
        // Use multiple methods to ensure accurate count
        const countCmd = `strings "${file}" 2>/dev/null | grep -c "Adreno (TM) ${source}" || echo 0`;
        const countRes = await exec(countCmd);
        let occurrences = countRes.stdout ? parseInt(countRes.stdout.trim()) : 0;
        
        // Fallback count using grep if strings gave 0
        if (occurrences === 0) {
            const grepCountCmd = `grep -o "Adreno (TM) ${source}" "${file}" 2>/dev/null | wc -l`;
            const grepCountRes = await exec(grepCountCmd);
            occurrences = grepCountRes.stdout ? parseInt(grepCountRes.stdout.trim()) : 0;
        }
        
        if (occurrences > 0) {
            logToTerminal(`  Found ${occurrences} occurrence(s) of "Adreno (TM) ${source}"`, 'info');
        } else {
            logToTerminal(`  No occurrences of source model in this file - skipping`, 'info');
            continue;
        }
        
        // 3. Apply patch using perl (binary-safe, handles ELF null bytes)
        const perlExpr = `s/Adreno \\(TM\\) ${source}/Adreno (TM) ${target}/g`;
        let res = await exec(`perl -pi -0777 -e '${perlExpr}' "${file}" 2>/dev/null`);
        if (res.errno !== 0) {
            // Fallback to sed if perl unavailable
            res = await exec(`sed -i 's/Adreno (TM) ${source}/Adreno (TM) ${target}/g' "${file}" 2>/dev/null`);
        }
        
        if (res.errno === 0) {
            // 4. Verify the patch was applied successfully 
            const verifyCmd = `strings "${file}" 2>/dev/null | grep -c "Adreno (TM) ${target}" || echo 0`;
            const verifyRes = await exec(verifyCmd);
            let newOccurrences = verifyRes.stdout ? parseInt(verifyRes.stdout.trim()) : 0;
            
            // Fallback verification using grep
            if (newOccurrences === 0) {
                const grepVerifyCmd = `grep -o "Adreno (TM) ${target}" "${file}" 2>/dev/null | wc -l`;
                const grepVerifyRes = await exec(grepVerifyCmd);
                newOccurrences = grepVerifyRes.stdout ? parseInt(grepVerifyRes.stdout.trim()) : 0;
            }
            
            if (newOccurrences > 0) {
                successCount++;
                totalPatches += newOccurrences;
                logToTerminal(`  ✓ Patched ${newOccurrences} occurrence(s) successfully`, 'success');
                
                // Additional verification - check file was modified vs SD backup
                const diffCheck = await exec(`diff -q "${file}" "${safeBackupPath}" 2>/dev/null`);
                if (diffCheck.errno === 1) { // diff returns 1 when files differ
                    logToTerminal(`  ✓ File modification confirmed`, 'success');
                }
            } else {
                logToTerminal(`  ⚠ Warning: Patch completed but verification shows 0 target occurrences`, 'warn');
            }
        } else {
            logToTerminal(`  ✗ Patch command failed: ${res.stderr || 'Unknown error'}`, 'error');
            
            // Restore from SD card backup if patch failed
            if (bakAlreadyExists || true) {
                await exec(`cp "${safeBackupPath}" "${file}" 2>/dev/null`);
                logToTerminal(`  Restored from backup due to patch failure`, 'info');
            }
        }
    }

    setLoading(false);
    
    // Generate detailed success/failure report 
    if (successCount > 0) {
        // Update statistics 
        incrementStat('spoofCount');
        
        const successMsg = `Spoof Applied Successfully!\n\nPatched: ${totalPatches} occurrence(s)\nFiles modified: ${successCount}/${filesProcessed}\nTransform: ${source} → ${target}\n\n⚠️ REBOOT REQUIRED for changes to take effect`;
        showToast(currentTranslations.msgSpoofSuccess || successMsg);
        logToTerminal(`✓ GPU SPOOF COMPLETED: ${source} -> ${target}`, 'success');
        logToTerminal(`  Total patches: ${totalPatches}`, 'success');
        logToTerminal(`  Files modified: ${successCount}/${filesProcessed}`, 'success');
        logToTerminal(`  Status: SUCCESS - Reboot required`, 'success');
    } else {
        const failMsg = `Spoof Failed!\n\nPossible reasons:\n• Source model "${source}" not found in binaries\n• Files are read-only\n• Pattern mismatch\n\nProcessed: ${filesProcessed} file(s)\nModified: 0 files`;
        showToast(currentTranslations.msgSpoofFail || failMsg);
        logToTerminal(`✗ GPU SPOOF FAILED: ${source} -> ${target}`, 'error');
        logToTerminal(`  Files processed: ${filesProcessed}`, 'error');
        logToTerminal(`  Files modified: 0`, 'error');
        logToTerminal(`  Recommendation: Verify source model exists in binaries`, 'error');
    }
}

// ============================================
// RESTORE ORIGINAL libgsl.so
// ============================================

async function restoreOriginalGSL() {
    const SD_BACKUP = `${SD_ROOT}/Backup`;

    // ─── PHASE 1: Check backup existence ───────────────────────────────────────
    // Show loading only during the async exec checks, then ALWAYS turn it off
    // before opening the ConfirmDialog.
    //
    // ROOT CAUSE OF THE ORIGINAL BUG:
    //   setLoading(true) shows the loading overlay at z-index:2000.
    //   ConfirmDialog then opens underneath it so the user cannot see or tap it.
    //   The dialog resolve never fires → loading spins forever.
    //
    // FIX: setLoading(false) before every dialog.show() call.
    //      Re-enable loading only after the user confirms and we start actual work.
    //      Wrap all real work in try/catch/finally so loading ALWAYS ends.

    setLoading(true);
    logToTerminal('Checking for original libgsl.so backups...', 'info');

    let libExists   = false;
    let lib64Exists = false;

    try {
        const libCheck   = await exec(`[ -f "${SD_BACKUP}/lib/libgsl.so" ]   && echo "exists" || echo "missing"`);
        const lib64Check = await exec(`[ -f "${SD_BACKUP}/lib64/libgsl.so" ] && echo "exists" || echo "missing"`);
        libExists   = !!(libCheck   && libCheck.stdout   && libCheck.stdout.includes('exists'));
        lib64Exists = !!(lib64Check && lib64Check.stdout && lib64Check.stdout.includes('exists'));
    } catch (e) {
        setLoading(false);
        const msg = e && e.message ? e.message : String(e);
        showToast('❌ Error checking backups: ' + msg);
        logToTerminal('Restore error (backup check): ' + msg, 'error');
        return;
    }

    // CRITICAL: turn off loading overlay BEFORE showing any dialog
    setLoading(false);

    if (!libExists && !lib64Exists) {
        showToast('⚠️ No original backup found. Apply GPU Spoof first to create a backup.');
        logToTerminal('Restore aborted: No backup found in Backup/lib/ or Backup/lib64/', 'warn');
        return;
    }

    logToTerminal(`Backup present — lib: ${libExists}, lib64: ${lib64Exists}`, 'info');

    // ─── PHASE 2: Confirm with user ────────────────────────────────────────────
    // Loading is OFF here — dialog is fully visible and interactive.
    const confirmed = await ConfirmDialog.show(
        'Restore Original libgsl.so',
        'This will restore the original (factory-stock) libgsl.so from backup.\n\n⚠️ REBOOT REQUIRED after restore.\n\nContinue?',
        '🔄'
    );

    if (!confirmed) {
        logToTerminal('Restore cancelled by user', 'info');
        return;
    }

    // ─── PHASE 3: Do the actual restore work ───────────────────────────────────
    // Turn loading back on now that the dialog is dismissed.
    // Wrap EVERYTHING in try/catch/finally so loading always ends.
    setLoading(true);

    try {
        // Find all libgsl.so files currently inside the module
        const findRes = await exec(`find "${MOD_PATH}/system/vendor" -name "libgsl.so" 2>/dev/null`);
        if (findRes.errno !== 0 || !findRes.stdout || !findRes.stdout.trim()) {
            showToast('⚠️ libgsl.so not found in module. Module may not be installed.');
            logToTerminal('Restore aborted: libgsl.so not found in module at ' + MOD_PATH, 'warn');
            return;
        }

        const files = findRes.stdout.trim().split('\n');
        let restoreCount = 0;
        let skipCount    = 0;
        let failCount    = 0;

        for (const file of files) {
            // Mirror the same lib/lib64 detection used during backup creation
            const libSubdir  = file.includes('/lib64/') ? 'lib64' : 'lib';
            const backupPath = `${SD_BACKUP}/${libSubdir}/libgsl.so`;

            // Verify the backup for this specific variant exists
            const bakCheck  = await exec(`[ -f "${backupPath}" ] && echo "exists" || echo "missing"`);
            const bakExists = !!(bakCheck && bakCheck.stdout && bakCheck.stdout.includes('exists'));

            if (!bakExists) {
                logToTerminal(`  No backup for ${libSubdir}/libgsl.so — skipping`, 'warn');
                skipCount++;
                continue;
            }

            logToTerminal(`  Restoring ${libSubdir}/libgsl.so → ${file}`, 'info');
            const restoreRes = await exec(`cp "${backupPath}" "${file}" 2>/dev/null`);
            if (restoreRes.errno === 0) {
                restoreCount++;
                logToTerminal(`  ✓ Restored: ${file}`, 'success');
            } else {
                failCount++;
                logToTerminal(`  ✗ Failed to restore: ${file}`, 'error');
            }
        }

        if (restoreCount > 0 && failCount === 0) {
            showToast(`✅ Original restored (${restoreCount} file(s)). Reboot required!`);
            logToTerminal(`✓ RESTORE COMPLETE: ${restoreCount} file(s) restored from original backup`, 'success');
            logToTerminal('  ⚠️ REBOOT REQUIRED for changes to take effect', 'success');
        } else if (restoreCount > 0) {
            showToast(`⚠️ Partial restore (${restoreCount} ok, ${failCount} failed). Reboot required!`);
            logToTerminal(`Restore partially complete: ${restoreCount} restored, ${failCount} failed`, 'warn');
        } else {
            showToast('❌ Restore failed. Check logs for details.');
            logToTerminal('✗ Restore FAILED — no files were restored', 'error');
        }

    } catch (e) {
        const msg = e && e.message ? e.message : String(e);
        logToTerminal('Restore error: ' + msg, 'error');
        showToast('❌ Restore error: ' + msg);
    } finally {
        // GUARANTEED: loading always ends, even if an exec throws or returns
        setLoading(false);
    }
}

// ============================================
// QUICK FIXES 
// ============================================

async function runFix(libs, name, warningKey) {
    // Show confirmation dialog with detailed warning 
    const warningTitle = currentTranslations[`${warningKey}Title`] || name;
    const warningMessage = currentTranslations[warningKey] || `This will remove libraries: ${libs}\n\nNote: This can only fix issues caused by module libraries. To restore, reflash the module.\n\nContinue?`;
    
    const confirmed = await ConfirmDialog.show(
        warningTitle,
        warningMessage,
        '⚠️'
    );
    
    if (!confirmed) {
        logToTerminal(`${name} cancelled by user`, 'info');
        return;
    }
    
    setLoading(true);
    logToTerminal(`Applying ${name}...`, 'info');

    try {
        const libArray = libs.split(' ');
        for (const lib of libArray) {
            await exec(`find "${MOD_PATH}/system" -name "${lib}" -type f -delete 2>/dev/null`);
        }
        
        // Update statistics 
        incrementStat('fixesApplied');
        
        showToast(`✅ ${name} Applied`);
        logToTerminal(`✓ ${name} applied successfully`, 'success');
    } catch (e) {
        logToTerminal(`runFix error: ${e && e.message ? e.message : String(e)}`, 'error');
        showToast(`❌ ${name} failed`);
    } finally {
        setLoading(false);
    }
}



// ============================================
// SYSTEM MAINTENANCE
// ============================================

async function clearGPUCaches() {
    const confirmed = await ConfirmDialog.show(
        currentTranslations.clearGPUCacheTitle || 'Clear GPU Caches',
        'This will remove all GPU shader and graphics caches. Continue?',
        '🗑️'
    );
    
    if (!confirmed) return;
    
    setLoading(true);
    logToTerminal('Clearing GPU caches...', 'info');

    try {
        // Use find-based removal — shell glob patterns like /data/.../cache/*shader*
        // are NOT reliably expanded in the WebUI exec() shell context.
        // find handles deep wildcard matching correctly and safely.
        
        // Shader / GPU cache directories and files in user_de, data, user
        await exec(`find /data/user_de -type d \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data/user_de -type f \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -delete 2>/dev/null; true`);
        await exec(`find /data/data -type d \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' -o -iname '*program*cache*' \\) -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data/data -type f \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' -o -iname '*program*cache*' \\) -delete 2>/dev/null; true`);
        await exec(`find /data/user -type d \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data/user -type f \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -delete 2>/dev/null; true`);
        
        // data_mirror shadow mounts (multi-user / work profile caches)
        await exec(`find /data_mirror/data_ce -type d \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data_mirror/data_ce -type f \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -delete 2>/dev/null; true`);
        await exec(`find /data_mirror/data_de -type d \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data_mirror/data_de -type f \\( -iname '*shader*' -o -iname '*gpucache*' -o -iname '*graphitecache*' -o -iname '*pipeline*' \\) -delete 2>/dev/null; true`);
        
        // OpenGL and Vulkan compiled shader caches
        await exec(`find /data -type d -path '*/code_cache/*/OpenGL' -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data -type d -path '*/code_cache/*/Vulkan' -exec rm -rf {} + 2>/dev/null; true`);
        await exec(`find /data -type d -name 'com.android.gl.*' -path '*/code_cache/*' -exec rm -rf {} + 2>/dev/null; true`);
        
        // System graphics stats (safe to clear)
        await exec(`rm -rf /data/system/graphicsstats/* 2>/dev/null; true`);
        
        showToast('✅ GPU Caches Cleared');
        logToTerminal('✓ GPU caches cleared successfully', 'success');
    } catch (e) {
        logToTerminal('clearGPUCaches error: ' + (e && e.message ? e.message : String(e)), 'error');
        showToast('❌ Failed to clear GPU caches');
    } finally {
        setLoading(false);
    }
}

async function trimStorage() {
    setLoading(true);
    logToTerminal('Running filesystem trim and memory cache drop...', 'info');

    try {
        // Flush all pending writes to disk before trimming
        await exec(`sync 2>/dev/null; true`);
        
        // fstrim tells the kernel to notify the storage device about
        // blocks no longer in use, improving flash performance and longevity.
        await exec(`fstrim -v /data 2>/dev/null; true`);
        await exec(`fstrim -v /cache 2>/dev/null; true`);
        await exec(`fstrim -v /system 2>/dev/null; true`);
        
        // Drop page cache, dentries and inodes to free RAM (safe with root on Android).
        await exec(`sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; true`);
        
        showToast(currentTranslations.msgTrimComplete || '✅ Storage optimized');
        logToTerminal('✓ Storage trim and cache drop completed', 'success');
    } catch (e) {
        logToTerminal('trimStorage error: ' + (e && e.message ? e.message : String(e)), 'error');
        showToast('❌ Storage trim failed');
    } finally {
        setLoading(false);
    }
}

// ============================================
// THEME MANAGEMENT
// ============================================

let currentTheme = 'purple';

function applyTheme(theme) {
    const validThemes = ['purple', 'amber', 'ocean', 'rose', 'forest'];
    if (!validThemes.includes(theme)) theme = 'purple';
    currentTheme = theme;

    // Trigger smooth theme transition
    document.documentElement.classList.add('theme-transitioning');
    setTimeout(() => document.documentElement.classList.remove('theme-transitioning'), 450);

    document.documentElement.setAttribute('data-theme', theme);
    
    // Update particle color
    if (particleBg) {
        const themeColors = {
            purple: 'rgba(139,92,246,0.55)',
            amber:  'rgba(212,146,42,0.55)',
            ocean:  'rgba(34,211,238,0.50)',
            rose:   'rgba(244,114,182,0.50)',
            forest: 'rgba(74,222,128,0.45)'
        };
        particleBg.currentColor = themeColors[theme] || themeColors.purple;
    }
    
    // Update swatch active state
    document.querySelectorAll('.theme-swatch').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.theme === theme);
    });
}

async function applyAndSaveTheme(theme) {
    applyTheme(theme);
    closeThemePicker();
    const swatchKey = `swatch${theme.charAt(0).toUpperCase() + theme.slice(1)}`;
    const label = currentTranslations[swatchKey] || (theme.charAt(0).toUpperCase() + theme.slice(1));
    showToast(`🎨 ${label}`);
    logToTerminal(`Theme changed to: ${theme}`, 'info');
    
    // Save theme to config file silently (no reboot dialog needed for UI changes)
    try {
        // Read existing config first
        const res = await exec(`cat "${SD_CONFIG}/adreno_config.txt" 2>/dev/null || cat "${MOD_PATH}/adreno_config.txt" 2>/dev/null`);
        let lines = [];
        if (res.errno === 0 && res.stdout) {
            lines = res.stdout.split('\n').filter(l => l.trim() && !l.startsWith('THEME='));
        }
        lines.push(`THEME=${theme}`);
        const config = lines.join('\n');
        const escaped = config.replace(/'/g, "'\\''");
        await exec(`echo '${escaped}' > "${SD_CONFIG}/adreno_config.txt"`);
        await exec(`echo '${escaped}' > "${MOD_PATH}/adreno_config.txt" 2>/dev/null`);
        logToTerminal(`✓ Theme saved to config`, 'success');
    } catch (e) {
        logToTerminal(`Theme save error: ${e.message}`, 'warn');
    }
}

function openThemePicker() {
    const modal = document.getElementById('themeModal');
    if (modal) modal.classList.add('open');
    updateColorModeUI();
}

function closeThemePicker() {
    const modal = document.getElementById('themeModal');
    if (modal) modal.classList.remove('open');
}

// ============================================
// COLOR MODE (Glass ↔ Vivid)
// ============================================

let currentColorMode = 'glass';
let _colorModeSwitching = false; // guard against rapid mode switches

// All 4 display mode CSS classes
const COLOR_MODE_CLASSES = ['vivid-mode', 'blur-mode', 'transparency-mode'];

function applyColorMode(mode) {
    // Debounce: ignore if a mode switch is already in progress
    if (_colorModeSwitching) return;
    _colorModeSwitching = true;
    setTimeout(() => { _colorModeSwitching = false; }, 400);

    currentColorMode = mode;

    // Add transition class for smooth mode switch
    document.documentElement.classList.add('mode-transitioning');
    setTimeout(() => document.documentElement.classList.remove('mode-transitioning'), 380);

    // Remove all mode classes
    COLOR_MODE_CLASSES.forEach(cls => document.documentElement.classList.remove(cls));
    // Apply the right class
    if (mode === 'full' || mode === 'vivid') {
        document.documentElement.classList.add('vivid-mode');
        currentColorMode = 'vivid';
    } else if (mode === 'blur') {
        document.documentElement.classList.add('blur-mode');
    } else if (mode === 'transparent') {
        document.documentElement.classList.add('transparency-mode');
    }
    // glass = no extra class (default)
    updateColorModeUI();
    try { localStorage.setItem('adreno_colormode', currentColorMode); } catch(e) {}
}

function updateColorModeUI() {
    document.querySelectorAll('.colormode-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.mode === currentColorMode);
    });
}

// ============================================
// QUALITY MODE — toggle heavy visual effects on/off
// ============================================

let currentQualityMode = false; // default OFF for performance

function applyQualityMode(enabled) {
    currentQualityMode = enabled;
    const html = document.documentElement;

    if (enabled) {
        html.classList.add('quality-mode');
        // Quality mode: more particles, higher FPS, glowing effects
        if (particleBg) {
            particleBg.performanceMode = false;
            particleBg.particleCount = Math.min(70, Math.floor(window.innerWidth / 9));
            // Reset DPR to 1.5 for quality
            const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
            particleBg.canvas.width  = window.innerWidth  * dpr;
            particleBg.canvas.height = window.innerHeight * dpr;
            particleBg.ctx = particleBg.canvas.getContext('2d', { alpha: true });
            particleBg.ctx.scale(dpr, dpr);
            particleBg.init();
        }
    } else {
        html.classList.remove('quality-mode');
        // Performance mode: fewer particles, lower FPS, DPR capped at 1.0, no heavy effects
        if (particleBg) {
            particleBg.performanceMode = true;
            particleBg.particleCount = Math.min(55, Math.floor(window.innerWidth / 8));
            // Reset DPR to 1.0 for performance
            const dpr = 1.0;
            particleBg.canvas.width  = window.innerWidth  * dpr;
            particleBg.canvas.height = window.innerHeight * dpr;
            particleBg.ctx = particleBg.canvas.getContext('2d', { alpha: true });
            particleBg.ctx.scale(dpr, dpr);
            particleBg.init();
        }
    }
    updateQualityUI(enabled);
    try { localStorage.setItem('adreno_quality', enabled ? '1' : '0'); } catch(e) {}
}

function updateQualityUI(enabled) {
    const icon  = document.getElementById('qualityIcon');
    const name  = document.getElementById('qualityName');
    const desc  = document.getElementById('qualityDesc');
    const hint  = document.getElementById('qualityHint');
    if (icon) icon.textContent = enabled ? '✨' : '⚡';
    if (name) name.textContent = enabled
        ? (currentTranslations.qualityModeOn  || 'Quality Mode')
        : (currentTranslations.qualityModeOff || 'Performance Mode');
    if (desc) desc.textContent = enabled
        ? (currentTranslations.qualityModeOnDesc  || 'All effects enabled')
        : (currentTranslations.qualityModeOffDesc || 'Smooth on all devices');
    if (hint) hint.textContent = enabled
        ? (currentTranslations.qualityHintOn  || 'Aurora, animations & blur active — disable if device lags')
        : (currentTranslations.qualityHintOff || 'Enable for aurora, animations & backdrop blur — may lag on older devices');
}

function initQualityMode() {
    try {
        const saved = localStorage.getItem('adreno_quality');
        const enabled = saved === '1';
        applyQualityMode(enabled);
    } catch(e) {}

    const btn = document.getElementById('btnQualityToggle');
    if (btn) {
        btn.addEventListener('click', () => {
            applyQualityMode(!currentQualityMode);
            showToast(currentQualityMode ? '✨ Quality Mode ON' : '⚡ Performance Mode ON');
        });
    }
}

function initColorModeToggle() {
    try {
        const saved = localStorage.getItem('adreno_colormode');
        if (saved) applyColorMode(saved);
    } catch(e) {}
    updateColorModeUI();
    document.querySelectorAll('.colormode-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const mode = btn.dataset.mode;
            applyColorMode(mode);
            const labels = {
                glass:       `🌙 ${currentTranslations.colorModeGlass  || 'Glass Mode'}`,
                blur:        `💧 ${currentTranslations.colorModeBlur   || 'Blur Mode'}`,
                transparent: `🪟 ${currentTranslations.colorModeClear  || 'Clear Mode'}`,
                vivid:       `✨ ${currentTranslations.colorModeVivid  || 'Vivid Mode'}`
            };
            showToast(labels[mode] || mode);
        });
    });
}

async function openDocs() {
    const modal = document.getElementById('docModal');
    if (!modal) return;
    
    modal.style.display = 'block';
    const content = document.getElementById('docContent');
    const btnTrans = document.getElementById('btnTransDocs');
    
    setLoading(true);
    logToTerminal('Loading documentation...', 'info');

    try {
        // Show/hide translate button based on language
        if (btnTrans) {
            if (currentLangCode === 'en') {
                btnTrans.style.display = 'none';
            } else {
                btnTrans.style.display = 'block';
                const langText = currentLangCode === 'custom' ? 'custom' : currentLangCode;
                btnTrans.textContent = `${currentTranslations.docTranslate || 'Translate'} to ${langText}`;
            }
        }
        
        let res;
        let fileToLoad = "README.md";
        
        // If not English, try to load custom_README.md first
        if (currentLangCode !== 'en') {
            const customCheck = await exec(`[ -f "${MOD_DOCS}/custom_README.md" ] && echo "exists"`);
            if (customCheck.stdout && customCheck.stdout.includes('exists')) {
                fileToLoad = "custom_README.md";
            }
        }
        
        // Try SD location first, then module location
        res = await exec(`cat "${SD_DOCS}/${fileToLoad}" 2>/dev/null || cat "${MOD_DOCS}/${fileToLoad}" 2>/dev/null`);
        
        // If custom not found, fallback to English
        if ((!res || res.errno !== 0 || !res.stdout || !res.stdout.trim()) && fileToLoad === "custom_README.md") {
            res = await exec(`cat "${SD_DOCS}/README.md" 2>/dev/null || cat "${MOD_DOCS}/README.md" 2>/dev/null`);
            fileToLoad = "README.md";
        }
        
        if (content) {
            if (res && res.errno === 0 && res.stdout && res.stdout.trim()) {
                // Basic markdown rendering
                let htmlContent = res.stdout
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/^### (.*$)/gim, '<h3>$1</h3>')
                    .replace(/^## (.*$)/gim, '<h2>$1</h2>')
                    .replace(/^# (.*$)/gim, '<h1>$1</h1>')
                    .replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>')
                    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
                    .replace(/\*(.+?)\*/g, '<em>$1</em>')
                    .replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>')
                    .replace(/`([^`]+)`/g, '<code>$1</code>')
                    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank">$1</a>')
                    .replace(/\n/g, '<br>');
                content.innerHTML = htmlContent;
                logToTerminal(`✓ Documentation loaded (${fileToLoad})`, 'success');
            } else {
                content.innerHTML = '<p style="color:var(--text-2)">Documentation not found.</p>';
                logToTerminal('Documentation not found', 'warn');
            }
        }
    } catch (e) {
        logToTerminal('openDocs error: ' + (e && e.message ? e.message : String(e)), 'error');
        showToast('❌ Failed to load documentation');
    } finally {
        setLoading(false);
    }
}

// ============================================
// CUSTOM DRIVER WIZARD — Custom Spoof & VKOnly
// Operates on arbitrary user-specified driver paths
// All binary patching via shell (sed/perl), same-length replacements only
// ============================================

// Wizard state — reset on each open
const _cdw = {
    feature: null,       // 'spoof' | 'vkonly'
    libMode: null,       // 'lib' | 'lib64' | 'both'
    libPath: '',
    lib64Path: '',
    turn: 'lib',         // current processing turn
    turnsCompleted: [],  // ['lib'] or ['lib'] then ['lib64']
    scannedModels: [],
    spoofSessions: [],   // [{sources:[], target:''}] applied this turn
    step: 'feature',     // 'feature' | 'libmode' | 'paths' | 'scan' | 'modelsel' | 'morespoofs' | 'vkfiles' | 'done'
};

// VKOnly rename map — all replacements are same byte-length (lib→not both 3 bytes)
const VKONLY_RENAMES = [
    { from: 'libadreno_utils.so', to: 'notadreno_utils.so' },
    { from: 'libgsl.so',          to: 'notgsl.so'          },
    { from: 'libllvm-glnext.so',  to: 'notllvm-glnext.so'  },
    { from: 'libllvm-qgl.so',     to: 'notllvm-qgl.so'     }
];
// The 5 files required for VKOnly (first 4 get renamed, all 5 get patched)
const VKONLY_FILES = [
    'libadreno_utils.so',
    'libgsl.so',
    'libllvm-glnext.so',
    'libllvm-qgl.so',
    'vulkan.adreno.so'
];

function openCustomDriverModal() {
    // Reset state
    _cdw.feature = null;
    _cdw.libMode = null;
    _cdw.libPath = '';
    _cdw.lib64Path = '';
    _cdw.turn = 'lib';
    _cdw.turnsCompleted = [];
    _cdw.scannedModels = [];
    _cdw.spoofSessions = [];
    _cdw.step = 'feature';

    const modal = document.getElementById('customDriverModal');
    if (modal) modal.style.display = 'block';
    _cdwRenderStep();
}

function closeCustomDriverModal() {
    const modal = document.getElementById('customDriverModal');
    if (modal) modal.style.display = 'none';
    // Ensure loading overlay is dismissed if closed mid-operation
    setLoading(false);
}

// Update the step dots in the step bar
function _cdwUpdateStepBar(stepIndex) {
    document.querySelectorAll('.wizard-step-dot').forEach((dot, i) => {
        dot.classList.toggle('active', i === stepIndex);
        dot.classList.toggle('done', i < stepIndex);
    });
}

function _cdwRenderStep() {
    const t = currentTranslations;
    const content = document.getElementById('customWizardContent');
    if (!content) return;

    switch (_cdw.step) {
        case 'feature':   _cdwRenderFeatureStep(content, t);  _cdwUpdateStepBar(0); break;
        case 'libmode':   _cdwRenderLibModeStep(content, t);  _cdwUpdateStepBar(1); break;
        case 'paths':     _cdwRenderPathsStep(content, t);    _cdwUpdateStepBar(1); break;
        case 'scan':      _cdwRenderScanStep(content, t);     _cdwUpdateStepBar(2); break;
        case 'modelsel':  _cdwRenderModelSelStep(content, t); _cdwUpdateStepBar(2); break;
        case 'morespoofs':_cdwRenderMoreSpoofs(content, t);   _cdwUpdateStepBar(2); break;
        case 'vkfiles':   _cdwRenderVKFilesStep(content, t);  _cdwUpdateStepBar(2); break;
        case 'done':      _cdwRenderDoneStep(content, t);     _cdwUpdateStepBar(2); break;
        default: break;
    }
}

function _cdwRenderFeatureStep(el, t) {
    el.innerHTML = `
        <div class="wizard-step-content">
            <h3 class="wizard-step-title">${t.customDriverChooseFeature || 'What do you want to do?'}</h3>
            <p class="wizard-step-desc">${t.customDriverChooseFeatureSub || 'Select the operation to perform on your driver files.'}</p>
            <div class="wizard-feature-grid">
                <button class="wizard-feature-card ripple-effect" id="cdwChooseSpoof">
                    <span class="wizard-feature-icon">🎭</span>
                    <span class="wizard-feature-name">${t.customDriverSpoofBtn || 'Custom GPU Spoof'}</span>
                    <span class="wizard-feature-desc">${t.customDriverSpoofBtnDesc || 'Spoof GPU model IDs in any libgsl.so'}</span>
                </button>
                <button class="wizard-feature-card ripple-effect" id="cdwChooseVKOnly">
                    <span class="wizard-feature-icon">⚡</span>
                    <span class="wizard-feature-name">${t.customDriverVKOnlyBtn || 'Make VKOnly'}</span>
                    <span class="wizard-feature-desc">${t.customDriverVKOnlyBtnDesc || 'Strip OpenGL to force Vulkan-only rendering'}</span>
                </button>
            </div>
        </div>`;

    const spoofBtn = document.getElementById('cdwChooseSpoof');
    const vkBtn = document.getElementById('cdwChooseVKOnly');
    if (spoofBtn) spoofBtn.addEventListener('click', () => {
        _cdw.feature = 'spoof';
        _cdw.step = 'libmode';
        _cdwRenderStep();
    });
    if (vkBtn) vkBtn.addEventListener('click', () => {
        _cdw.feature = 'vkonly';
        _cdw.step = 'libmode';
        _cdwRenderStep();
    });
}

function _cdwRenderLibModeStep(el, t) {
    el.innerHTML = `
        <div class="wizard-step-content">
            <button class="wizard-back-inline ripple-effect" id="cdwBackToFeature">‹ ${t.wizardBack || 'Back'}</button>
            <h3 class="wizard-step-title">${t.customDriverLibMode || 'Does the driver have lib and lib64?'}</h3>
            <p class="wizard-step-desc">${t.customDriverLibModeSub || 'Select which directories are present in your driver.'}</p>
            <div class="wizard-libmode-grid">
                <button class="wizard-libmode-btn ripple-effect" id="cdwLibOnly">
                    <span class="wizard-libmode-icon">📁</span>
                    <span>${t.customDriverLibOnly || 'lib only'}</span>
                </button>
                <button class="wizard-libmode-btn ripple-effect" id="cdwLib64Only">
                    <span class="wizard-libmode-icon">📁</span>
                    <span>${t.customDriverLib64Only || 'lib64 only'}</span>
                </button>
                <button class="wizard-libmode-btn ripple-effect accent" id="cdwBoth">
                    <span class="wizard-libmode-icon">📂</span>
                    <span>${t.customDriverBoth || 'Both lib + lib64'}</span>
                </button>
            </div>
        </div>`;

    document.getElementById('cdwBackToFeature').addEventListener('click', () => { _cdw.step = 'feature'; _cdwRenderStep(); });
    document.getElementById('cdwLibOnly').addEventListener('click', () => { _cdw.libMode = 'lib'; _cdw.turn = 'lib'; _cdw.step = 'paths'; _cdwRenderStep(); });
    document.getElementById('cdwLib64Only').addEventListener('click', () => { _cdw.libMode = 'lib64'; _cdw.turn = 'lib64'; _cdw.step = 'paths'; _cdwRenderStep(); });
    document.getElementById('cdwBoth').addEventListener('click', () => { _cdw.libMode = 'both'; _cdw.turn = 'lib'; _cdw.step = 'paths'; _cdwRenderStep(); });
}

function _cdwRenderPathsStep(el, t) {
    const showLib = (_cdw.libMode === 'lib' || _cdw.libMode === 'both');
    const showLib64 = (_cdw.libMode === 'lib64' || _cdw.libMode === 'both');
    const isVK = _cdw.feature === 'vkonly';

    el.innerHTML = `
        <div class="wizard-step-content">
            <button class="wizard-back-inline ripple-effect" id="cdwBackToLibMode">‹ ${t.wizardBack || 'Back'}</button>
            <h3 class="wizard-step-title">${t.customDriverEnterPath || 'Enter driver lib path'}</h3>
            <p class="wizard-step-desc">${t.customDriverEnterPathSub || 'Provide the full path to the driver lib folder on your device.'}</p>
            ${showLib ? `
            <div class="wizard-path-group">
                <label class="wizard-path-label">${t.customDriverLibPathLabel || 'lib folder path'}</label>
                <input type="text" id="cdwLibPathInput" class="input-glass premium-input wizard-path-input"
                    placeholder="${t.customDriverPathPlaceholder || '/sdcard/MyDriver/system/vendor/lib'}"
                    value="${_cdw.libPath}" autocomplete="off" spellcheck="false"/>
            </div>` : ''}
            ${showLib64 ? `
            <div class="wizard-path-group">
                <label class="wizard-path-label">${t.customDriverLib64PathLabel || 'lib64 folder path'}</label>
                <input type="text" id="cdwLib64PathInput" class="input-glass premium-input wizard-path-input"
                    placeholder="${t.customDriverPath64Placeholder || '/sdcard/MyDriver/system/vendor/lib64'}"
                    value="${_cdw.lib64Path}" autocomplete="off" spellcheck="false"/>
            </div>` : ''}
            ${isVK ? `<div class="info-banner modern-info" style="margin-top:12px;">
                <span class="info-icon">ℹ️</span>
                <p class="info-text">${t.customDriverVKOnlyOutput || 'Modified files will be saved to:'} <strong>/sdcard/Adreno_Driver/VKOnly/</strong></p>
            </div>` : `
            <div class="info-banner warning-banner" style="margin-top:12px;border-color:var(--warning,#f59e0b);background:rgba(245,158,11,0.10);">
                <span class="info-icon">🚨</span>
                <p class="info-text" style="color:var(--warning,#f59e0b);">${t.customDriverVendorWarning || '⚠️ Do NOT enter a path pointing to /vendor/ or /system/. Never spoof libgsl.so in a live environment — it WILL cause a bootloop. Work on files copied to /sdcard/ only.'}</p>
            </div>
            <div class="info-banner modern-info" style="margin-top:8px;">
                <span class="info-icon">📂</span>
                <p class="info-text">${t.customDriverBackupInfo || 'Backup of original libgsl.so saved to:'} <strong>/sdcard/Adreno_Driver/Backup/custom/{lib|lib64}/</strong></p>
            </div>`}
            <button class="btn-primary full-width ripple-effect modern-btn-large" id="cdwConfirmPaths" style="margin-top:18px;">
                <span class="btn-icon">${isVK ? '⚡' : '🔍'}</span>
                <span>${isVK ? (t.customDriverVKOnlyProcess || 'Apply VKOnly') : (t.customDriverScanBtn || 'Scan GPU Models')}</span>
            </button>
        </div>`;

    document.getElementById('cdwBackToLibMode').addEventListener('click', () => { _cdw.step = 'libmode'; _cdwRenderStep(); });
    document.getElementById('cdwConfirmPaths').addEventListener('click', async () => {
        // Read path values
        const libInput = document.getElementById('cdwLibPathInput');
        const lib64Input = document.getElementById('cdwLib64PathInput');
        if (libInput) _cdw.libPath = libInput.value.trim().replace(/\/+$/, '');
        if (lib64Input) _cdw.lib64Path = lib64Input.value.trim().replace(/\/+$/, '');

        // Validate required paths
        const needLib = (_cdw.libMode === 'lib' || _cdw.libMode === 'both');
        const needLib64 = (_cdw.libMode === 'lib64' || _cdw.libMode === 'both');
        if (needLib && !_cdw.libPath) { showToast('⚠️ Please enter the lib path.'); return; }
        if (needLib64 && !_cdw.lib64Path) { showToast('⚠️ Please enter the lib64 path.'); return; }

        if (_cdw.feature === 'vkonly') {
            await _cdwStartVKOnly();
        } else {
            _cdw.turn = (_cdw.libMode === 'lib64') ? 'lib64' : 'lib';
            _cdw.step = 'scan';
            _cdwRenderStep();
            await _cdwDoScan();
        }
    });
}

async function _cdwDoScan() {
    const t = currentTranslations;
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;
    const gslPath = `${currentPath}/libgsl.so`;

    const scanStatus = document.getElementById('cdwScanStatus');
    if (scanStatus) scanStatus.textContent = t.customDriverScanning || 'Scanning GPU models...';

    setLoading(true);
    logToTerminal(`Custom Spoof: Scanning ${gslPath}`, 'info');

    try {
        // Check file exists
        const existCheck = await exec(`[ -f "${gslPath}" ] && echo "exists" || echo "missing"`);
        if (!existCheck.stdout || !existCheck.stdout.includes('exists')) {
            setLoading(false);
            showToast(t.customDriverLibgslNotFound || 'libgsl.so not found in the specified path.');
            logToTerminal(`Custom Spoof: libgsl.so not found at ${gslPath}`, 'error');
            if (scanStatus) scanStatus.textContent = '❌ ' + (t.customDriverLibgslNotFound || 'libgsl.so not found.');
            return;
        }

        let allModels = new Set();

        // Method 1: strings + grep (best for binaries)
        const r1 = await exec(`strings "${gslPath}" 2>/dev/null | grep -oE "Adreno \\(TM\\) [0-9]{3,4}" | grep -oE "[0-9]{3,4}" | sort -u`);
        if (r1.errno === 0 && r1.stdout && r1.stdout.trim()) {
            r1.stdout.trim().split('\n').forEach(m => { const s = m.trim(); if (/^\d{3,4}$/.test(s)) allModels.add(s); });
        }

        if (allModels.size === 0) {
            const r2 = await exec(`grep -aoE "Adreno \\(TM\\) [0-9]{3,4}" "${gslPath}" 2>/dev/null | grep -oE "[0-9]{3,4}" | sort -u`);
            if (r2.errno === 0 && r2.stdout && r2.stdout.trim()) {
                r2.stdout.trim().split('\n').forEach(m => { const s = m.trim(); if (/^\d{3,4}$/.test(s)) allModels.add(s); });
            }
        }

        if (allModels.size === 0) {
            const r3 = await exec(`strings "${gslPath}" 2>/dev/null | grep -oE "Adreno [0-9]{3,4}" | grep -oE "[0-9]{3,4}" | sort -u`);
            if (r3.errno === 0 && r3.stdout && r3.stdout.trim()) {
                r3.stdout.trim().split('\n').forEach(m => { const s = m.trim(); if (/^\d{3,4}$/.test(s) && parseInt(s) >= 200) allModels.add(s); });
            }
        }

        _cdw.scannedModels = Array.from(allModels).sort((a, b) => parseInt(a) - parseInt(b));
        logToTerminal(`Custom Spoof: Found models: ${_cdw.scannedModels.join(', ') || 'none'}`, _cdw.scannedModels.length > 0 ? 'success' : 'warn');

        setLoading(false);

        if (_cdw.scannedModels.length === 0) {
            showToast(t.customDriverNoModels || 'No Adreno models found in this file.');
            if (scanStatus) scanStatus.textContent = '⚠️ ' + (t.customDriverNoModels || 'No models found.');
            return;
        }

        _cdw.spoofSessions = [];
        _cdw.step = 'modelsel';
        _cdwRenderStep();
    } catch (e) {
        setLoading(false);
        const msg = e && e.message ? e.message : String(e);
        logToTerminal('Custom Spoof scan error: ' + msg, 'error');
        showToast('❌ Scan error: ' + msg);
    }
}

function _cdwRenderScanStep(el, t) {
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;
    el.innerHTML = `
        <div class="wizard-step-content">
            <div class="wizard-scanning-state">
                <div class="spinner-mini active" style="width:36px;height:36px;border-width:3px;margin:0 auto 16px;">
                    <div class="spinner-ring"></div>
                </div>
                <p id="cdwScanStatus" class="wizard-scan-status">${t.customDriverScanning || 'Scanning GPU models...'}</p>
                <p class="wizard-step-desc" style="margin-top:8px;">${currentPath}/libgsl.so</p>
            </div>
        </div>`;
}

function _cdwRenderModelSelStep(el, t) {
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;
    const models = _cdw.scannedModels;

    el.innerHTML = `
        <div class="wizard-step-content">
            <button class="wizard-back-inline ripple-effect" id="cdwBackToPaths">‹ ${t.wizardBack || 'Back'}</button>
            <div class="wizard-turn-badge">${t.customDriverCurrentTurn || 'Processing:'} <strong>${_cdw.turn}</strong></div>
            <h3 class="wizard-step-title">${t.customDriverScanResults || 'GPU Models Found'}</h3>
            <p class="wizard-step-desc">${t.customDriverScanResultsSub || 'Select one or more source models to spoof'}</p>
            <p class="wizard-path-hint" style="word-break:break-all;font-size:11px;color:var(--text-3);margin-bottom:12px;">${currentPath}/libgsl.so</p>

            <p class="wizard-label">${t.customDriverSelectSources || 'Select source GPU models:'}</p>
            <div class="wizard-model-list" id="cdwModelList">
                ${models.map(m => `
                <label class="wizard-model-item ripple-effect">
                    <input type="checkbox" class="cdw-model-cb" value="${m}">
                    <span class="wizard-model-name">Adreno (TM) <strong>${m}</strong></span>
                </label>`).join('')}
            </div>

            <div class="info-banner warning-banner" style="margin:12px 0;border-color:var(--warning,#f59e0b);background:rgba(245,158,11,0.10);">
                <span class="info-icon">🚨</span>
                <p class="info-text" style="color:var(--warning,#f59e0b);">${t.customDriverGSLMixWarning || '⚠️ Do NOT mix this libgsl.so with any other driver. Only pair it with the exact driver it came from. Using it with a different driver WILL cause a bootloop.'}</p>
            </div>

            <div class="info-banner modern-info" style="margin-bottom:12px;">
                <span class="info-icon">📂</span>
                <p class="info-text">${t.customDriverBackupInfo || 'Backup of original libgsl.so saved to:'} <strong>/sdcard/Adreno_Driver/Backup/custom/${_cdw.turn}/</strong></p>
            </div>

            <p class="wizard-label" style="margin-top:16px;">${t.customDriverTargetLabel || 'Spoof all selected → Target GPU model:'}</p>
            <input type="number" id="cdwTargetInput" class="input-glass premium-input" placeholder="${t.customDriverTargetPlaceholder || 'e.g. 750'}" min="200" max="9999" style="width:100%;margin-bottom:16px;">

            <button class="btn-primary full-width ripple-effect modern-btn-large" id="cdwApplyThisSpoof">
                <span>${t.customDriverApplySpoof || '✅ Apply This Spoof'}</span>
            </button>
        </div>`;

    document.getElementById('cdwBackToPaths').addEventListener('click', () => { _cdw.step = 'paths'; _cdwRenderStep(); });
    document.getElementById('cdwApplyThisSpoof').addEventListener('click', async () => {
        const checked = Array.from(document.querySelectorAll('.cdw-model-cb:checked')).map(cb => cb.value);
        const target = (document.getElementById('cdwTargetInput')?.value || '').trim();
        if (checked.length === 0) { showToast('⚠️ Select at least one source model.'); return; }
        if (!/^\d{3,4}$/.test(target)) { showToast('⚠️ Target must be 3 or 4 digits.'); return; }
        // Safety: all sources must match target digit length
        const badSrc = checked.find(s => s.length !== target.length);
        if (badSrc) {
            showToast(t.customDriverSpoofSafetyError || 'Source and target must have the same digit count!');
            logToTerminal(`Safety block: ${badSrc} (${badSrc.length}d) vs target ${target} (${target.length}d)`, 'error');
            return;
        }
        // Apply spoof for each source model
        await _cdwApplySpoofSession(checked, target);
    });
}

async function _cdwApplySpoofSession(sources, target) {
    const t = currentTranslations;
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;
    const gslPath = `${currentPath}/libgsl.so`;
    const SD_BACKUP = `${SD_ROOT}/Backup/custom/${_cdw.turn}`;

    setLoading(true);
    logToTerminal(`Custom Spoof: Applying ${sources.join(',')} → ${target} in ${gslPath}`, 'info');

    try {
        // Ensure backup dir exists
        await exec(`mkdir -p "${SD_BACKUP}" 2>/dev/null`);

        // First-backup-wins rule
        const bakPath = `${SD_BACKUP}/libgsl.so`;
        const bakCheck = await exec(`[ -f "${bakPath}" ] && echo "exists" || echo "missing"`);
        if (bakCheck.stdout && bakCheck.stdout.includes('missing')) {
            await exec(`cp "${gslPath}" "${bakPath}" 2>/dev/null`);
            logToTerminal(`Custom Spoof: Backup created at ${bakPath}`, 'info');
        }

        let totalPatched = 0;
        for (const source of sources) {
            const countRes = await exec(`strings "${gslPath}" 2>/dev/null | grep -c "Adreno (TM) ${source}" || echo 0`);
            const count = countRes.stdout ? parseInt(countRes.stdout.trim()) : 0;

            if (count > 0) {
                // perl -pi -0777: binary-safe, handles null bytes without corrupting ELF
                const perlExpr = `s/Adreno \\(TM\\) ${source}/Adreno (TM) ${target}/g`;
                let patchRes = await exec(`perl -pi -0777 -e '${perlExpr}' "${gslPath}" 2>/dev/null`);
                if (patchRes.errno !== 0) {
                    logToTerminal(`  perl unavailable, falling back to sed...`, 'warn');
                    patchRes = await exec(`sed -i 's/Adreno (TM) ${source}/Adreno (TM) ${target}/g' "${gslPath}" 2>/dev/null`);
                }
                if (patchRes.errno === 0) {
                    totalPatched += count;
                    logToTerminal(`  ✓ ${source} → ${target}: ${count} occurrence(s) patched`, 'success');
                } else {
                    logToTerminal(`  ✗ Failed to patch ${source}: ${patchRes.stderr || 'unknown error'}`, 'error');
                }
            } else {
                logToTerminal(`  ⚠ "${source}" not found in ${gslPath}`, 'warn');
            }
        }

        setLoading(false);

        // Record this session
        _cdw.spoofSessions.push({ sources: [...sources], target });

        if (totalPatched > 0) {
            showToast(`✅ Patched ${totalPatched} occurrence(s). Sources: [${sources.join(', ')}] → ${target}`);
            logToTerminal(`Custom Spoof turn done: ${totalPatched} patches applied`, 'success');
            incrementStat('spoofCount');
        } else {
            showToast('⚠️ No occurrences found to patch.');
        }

        // Ask if user wants more spoofs
        _cdw.step = 'morespoofs';
        _cdwRenderStep();

    } catch (e) {
        setLoading(false);
        const msg = e && e.message ? e.message : String(e);
        logToTerminal('Custom Spoof apply error: ' + msg, 'error');
        showToast('❌ Spoof error: ' + msg);
    }
}

function _cdwRenderMoreSpoofs(el, t) {
    const sessions = _cdw.spoofSessions;
    const hasBothAndLib64Pending = _cdw.libMode === 'both' && !_cdw.turnsCompleted.includes('lib64');

    el.innerHTML = `
        <div class="wizard-step-content">
            <div class="wizard-success-icon">✅</div>
            <h3 class="wizard-step-title">${t.customDriverMoreSpoofs || 'Do you want to spoof more models?'}</h3>
            <p class="wizard-step-desc">${t.customDriverMoreSpoofsSub || 'You can map another set of source models to a different target.'}</p>
            <div class="wizard-sessions-log">
                ${sessions.map(s => `<div class="wizard-session-tag">[${s.sources.join(', ')}] → ${s.target}</div>`).join('')}
            </div>
            <div class="wizard-feature-grid" style="margin-top:16px;">
                <button class="wizard-feature-card ripple-effect" id="cdwYesMore">
                    <span class="wizard-feature-icon">🔁</span>
                    <span class="wizard-feature-name">${t.customDriverYesMore || 'Yes, spoof more'}</span>
                </button>
                <button class="wizard-feature-card ripple-effect" id="cdwNoDone">
                    <span class="wizard-feature-icon">✅</span>
                    <span class="wizard-feature-name">${t.customDriverNoDone || 'No, I\'m done'}</span>
                </button>
            </div>
        </div>`;

    document.getElementById('cdwYesMore').addEventListener('click', () => {
        // Go back to model selection for same turn (models already scanned)
        _cdw.step = 'modelsel';
        _cdwRenderStep();
    });

    document.getElementById('cdwNoDone').addEventListener('click', async () => {
        // Mark this turn done
        _cdw.turnsCompleted.push(_cdw.turn);

        if (_cdw.libMode === 'both' && !_cdw.turnsCompleted.includes('lib64')) {
            // Move to lib64 turn
            _cdw.turn = 'lib64';
            _cdw.spoofSessions = [];
            _cdw.scannedModels = [];
            _cdw.step = 'scan';
            _cdwRenderStep();
            await _cdwDoScan();
        } else {
            _cdw.step = 'done';
            _cdwRenderStep();
        }
    });
}

async function _cdwStartVKOnly() {
    const t = currentTranslations;
    // Determine turns to process
    const turns = [];
    if (_cdw.libMode === 'lib' || _cdw.libMode === 'both') turns.push('lib');
    if (_cdw.libMode === 'lib64' || _cdw.libMode === 'both') turns.push('lib64');

    _cdw.turn = turns[0];
    _cdw.step = 'vkfiles';
    _cdwRenderStep();
}

function _cdwRenderVKFilesStep(el, t) {
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;

    el.innerHTML = `
        <div class="wizard-step-content">
            <button class="wizard-back-inline ripple-effect" id="cdwVKBackToPaths">‹ ${t.wizardBack || 'Back'}</button>
            <div class="wizard-turn-badge">${t.customDriverCurrentTurn || 'Processing:'} <strong>${_cdw.turn}</strong></div>
            <h3 class="wizard-step-title">${t.customDriverVKOnlyTitle || 'Select Driver Files'}</h3>
            <p class="wizard-step-desc">${t.customDriverVKOnlyInstructions || 'Select the 5 required files from the driver\'s'} <strong>${_cdw.turn}</strong> ${t.customDriverEnterPath ? '' : 'folder:'}</p>
            <p class="wizard-path-hint">${currentPath}/</p>

            <div class="info-banner modern-info" style="margin: 10px 0;">
                <span class="info-icon">ℹ️</span>
                <p class="info-text">${t.customDriverVKOnlyNote || 'The first 4 will be renamed (lib→not). All 5 will have internal references patched.'}</p>
            </div>

            <p class="wizard-label">${t.customDriverVKOnlyFileList || 'Required files:'}</p>
            <div class="wizard-vkonly-filelist">
                ${VKONLY_FILES.map((f, i) => `
                <div class="wizard-vkfile-row">
                    <span class="wizard-vkfile-name">${f}</span>
                    ${i < 4 ? `<span class="wizard-vkfile-rename">→ ${f.replace('lib', 'not')}</span>` : '<span class="wizard-vkfile-patch-only">patch only</span>'}
                </div>`).join('')}
            </div>

            <div class="info-banner modern-info" style="margin: 12px 0;">
                <span class="info-icon">📂</span>
                <p class="info-text">${t.customDriverVKOnlyOutput || 'Modified files will be saved to:'} <strong>/sdcard/Adreno_Driver/VKOnly/${_cdw.turn}/</strong></p>
            </div>

            <p class="wizard-step-desc" style="margin-bottom:4px;">The driver will be read from the path you entered. All 5 files must exist in that directory.</p>

            <div class="info-banner modern-info" style="margin: 8px 0 12px;">
                <span class="info-icon">💡</span>
                <p class="info-text">${t.customDriverVulkanHwNote || 'Note: vulkan.adreno.so may be located in lib64/ or lib64/hw/ — the tool checks both locations automatically.'}</p>
            </div>

            <button class="btn-primary full-width ripple-effect modern-btn-large" id="cdwDoVKOnly" style="margin-top:12px;">
                <span class="btn-icon">⚡</span>
                <span>${t.customDriverVKOnlyProcess || 'Apply VKOnly'}</span>
            </button>
        </div>`;

    document.getElementById('cdwVKBackToPaths').addEventListener('click', () => { _cdw.step = 'paths'; _cdwRenderStep(); });
    document.getElementById('cdwDoVKOnly').addEventListener('click', async () => await _cdwApplyVKOnly());
}

async function _cdwApplyVKOnly() {
    const t = currentTranslations;
    const currentPath = _cdw.turn === 'lib64' ? _cdw.lib64Path : _cdw.libPath;
    const outDir = `${SD_ROOT}/VKOnly/${_cdw.turn}`;

    setLoading(true);
    logToTerminal(`VKOnly: Starting for ${_cdw.turn} at ${currentPath}`, 'info');

    try {
        // ── PHASE 1: Resolve actual paths for all 5 files ──────────────────────
        // vulkan.adreno.so may live in currentPath/ OR currentPath/hw/
        // We resolve and store the real absolute path for every file RIGHT HERE,
        // so the copy loop never has to guess — no second exec, no race, no fallback bug.
        const resolvedPaths = {}; // srcFile → absolute path string

        for (const f of VKONLY_FILES) {
            if (f === 'vulkan.adreno.so') {
                // Priority: check root first, then hw/
                const rootPath = `${currentPath}/${f}`;
                const hwPath   = `${currentPath}/hw/${f}`;
                const chkRoot  = await exec(`[ -f "${rootPath}" ] && echo "yes"`);
                const chkHw    = await exec(`[ -f "${hwPath}" ] && echo "yes"`);
                const inRoot   = !!(chkRoot.stdout && chkRoot.stdout.trim() === 'yes');
                const inHw     = !!(chkHw.stdout   && chkHw.stdout.trim()   === 'yes');

                if (inRoot) {
                    resolvedPaths[f] = rootPath;
                    logToTerminal(`VKOnly: ${f} → ${rootPath}`, 'info');
                } else if (inHw) {
                    resolvedPaths[f] = hwPath;
                    logToTerminal(`VKOnly: ${f} → ${hwPath} (hw/ subdir)`, 'info');
                } else {
                    setLoading(false);
                    showToast(`❌ Missing: ${f} — not found in ${currentPath}/ or ${currentPath}/hw/`);
                    logToTerminal(`VKOnly: ${f} not found in either:\n  ${rootPath}\n  ${hwPath}`, 'error');
                    return;
                }
            } else {
                const p = `${currentPath}/${f}`;
                const chk = await exec(`[ -f "${p}" ] && echo "yes"`);
                if (!(chk.stdout && chk.stdout.trim() === 'yes')) {
                    setLoading(false);
                    showToast(`❌ Missing: ${f} in ${currentPath}`);
                    logToTerminal(`VKOnly: ${f} not found at ${p}`, 'error');
                    return;
                }
                resolvedPaths[f] = p;
                logToTerminal(`VKOnly: ${f} → ${p}`, 'info');
            }
        }

        // Create output dir
        await exec(`mkdir -p "${outDir}" 2>/dev/null`);
        logToTerminal(`VKOnly: Output dir: ${outDir}`, 'info');

        // Build perl inline replacement command — same length replacements, binary-safe
        // Each lib→not is exactly 3 bytes replacing 3 bytes — no ELF corruption
        const perlCmd = VKONLY_RENAMES.map(r => {
            // Escape dots in regex
            const fromEsc = r.from.replace(/\./g, '\\.');
            return `s/${fromEsc}/${r.to}/g`;
        }).join('; ');

        let filesProcessed = 0;
        let filesFailed = 0;

        for (let i = 0; i < VKONLY_FILES.length; i++) {
            const srcFile = VKONLY_FILES[i];
            const isRename = i < 4; // first 4 get renamed
            const destName = isRename ? srcFile.replace('lib', 'not') : srcFile;
            const destPath = `${outDir}/${destName}`;

            // Use the already-resolved absolute path — no re-checking needed
            const srcPath = resolvedPaths[srcFile];

            logToTerminal(`VKOnly: Processing ${srcFile} → ${destName}`, 'info');

            // Copy to output location with new name
            const cpRes = await exec(`cp "${srcPath}" "${destPath}" 2>/dev/null`);
            if (cpRes.errno !== 0) {
                logToTerminal(`  ✗ Failed to copy ${srcFile}`, 'error');
                filesFailed++;
                continue;
            }

            // Apply binary string patching with perl (handles null bytes, binary-safe)
            // perl -pi -0777 -e processes entire file as one string, handles binary
            const patchRes = await exec(`perl -pi -0777 -e '${perlCmd}' "${destPath}" 2>/dev/null`);
            if (patchRes.errno === 0) {
                logToTerminal(`  ✓ ${srcFile} → ${destName} (patched)`, 'success');
                filesProcessed++;
            } else {
                // Fallback to sed if perl unavailable
                logToTerminal(`  perl unavailable, trying sed fallback...`, 'warn');
                let sedOk = true;
                for (const r of VKONLY_RENAMES) {
                    const fromEsc = r.from.replace(/\./g, '\\.').replace(/\//g, '\\/');
                    const toEsc = r.to.replace(/\//g, '\\/');
                    const sedRes = await exec(`sed -i 's/${fromEsc}/${toEsc}/g' "${destPath}" 2>/dev/null`);
                    if (sedRes.errno !== 0) { sedOk = false; break; }
                }
                if (sedOk) {
                    logToTerminal(`  ✓ ${srcFile} → ${destName} (patched via sed)`, 'success');
                    filesProcessed++;
                } else {
                    logToTerminal(`  ✗ Patching failed for ${srcFile}`, 'error');
                    filesFailed++;
                }
            }
        }

        setLoading(false);

        if (filesProcessed > 0) {
            incrementStat('fixesApplied');
            logToTerminal(`VKOnly: Done. ${filesProcessed}/${VKONLY_FILES.length} files processed → ${outDir}`, 'success');
        }

        // Check if we need to do lib64 next
        _cdw.turnsCompleted.push(_cdw.turn);
        if (_cdw.libMode === 'both' && !_cdw.turnsCompleted.includes('lib64')) {
            _cdw.turn = 'lib64';
            // Show brief success then continue
            showToast(`✅ lib VKOnly done. Proceeding to lib64...`);
            _cdw.step = 'vkfiles';
            _cdwRenderStep();
        } else {
            _cdw.step = 'done';
            _cdwRenderStep();
            if (filesProcessed === VKONLY_FILES.length) {
                showToast(t.customDriverVKOnlyComplete || '✅ VKOnly applied! Files saved.');
            } else if (filesProcessed > 0) {
                showToast(`⚠️ VKOnly partial: ${filesProcessed}/${VKONLY_FILES.length} files.`);
            } else {
                showToast(t.customDriverVKOnlyFail || '❌ VKOnly failed. Check logs.');
            }
        }

    } catch (e) {
        setLoading(false);
        const msg = e && e.message ? e.message : String(e);
        logToTerminal('VKOnly error: ' + msg, 'error');
        showToast('❌ VKOnly error: ' + msg);
    }
}

function _cdwRenderDoneStep(el, t) {
    const isVK = _cdw.feature === 'vkonly';
    const outNote = isVK
        ? `${t.customDriverVKOnlyOutput || 'Modified files saved to:'} <strong>/sdcard/Adreno_Driver/VKOnly/</strong>`
        : (t.customDriverSpoofComplete || 'Spoof applied! Flash the modified driver to apply it.');

    el.innerHTML = `
        <div class="wizard-step-content wizard-done-state">
            <div class="wizard-success-icon" style="font-size:56px;margin-bottom:16px;">${isVK ? '⚡' : '🎭'}</div>
            <h3 class="wizard-step-title">${isVK ? (t.customDriverVKOnlyComplete || 'VKOnly Applied!') : (t.customDriverSpoofComplete || 'Spoof Applied!')}</h3>
            <p class="wizard-step-desc">${outNote}</p>
            ${!isVK ? `
            <div class="info-banner warning-banner" style="margin-top:14px;border-color:var(--warning,#f59e0b);background:rgba(245,158,11,0.10);">
                <span class="info-icon">🚨</span>
                <p class="info-text" style="color:var(--warning,#f59e0b);">${t.customDriverFlashToApply || 'Flash the spoofed driver to your device for changes to take effect. Do NOT simply reboot — the modified file must be flashed first.'}</p>
            </div>
            <div class="info-banner warning-banner" style="margin-top:8px;border-color:var(--warning,#f59e0b);background:rgba(245,158,11,0.10);">
                <span class="info-icon">⚠️</span>
                <p class="info-text" style="color:var(--warning,#f59e0b);">${t.customDriverGSLMixWarning || '⚠️ Do NOT mix this libgsl.so with any other driver. Only pair it with the exact driver it came from.'}</p>
            </div>
            <div class="info-banner modern-info" style="margin-top:8px;">
                <span class="info-icon">📂</span>
                <p class="info-text">${t.customDriverBackupInfo || 'Backup of original libgsl.so saved to:'} <strong>/sdcard/Adreno_Driver/Backup/custom/</strong></p>
            </div>` : ''}
            <button class="btn-secondary full-width ripple-effect modern-btn-large" id="cdwClose" style="margin-top:20px;">
                <span>${t.confirmOk || 'Done'}</span>
            </button>
        </div>`;
    document.getElementById('cdwClose').addEventListener('click', closeCustomDriverModal);
}

// ============================================
// INITIALIZATION
// ============================================

// Polyfill requestIdleCallback for environments that don't support it
const rIC = window.requestIdleCallback
    ? window.requestIdleCallback.bind(window)
    : (cb) => setTimeout(cb, 16);

document.addEventListener('DOMContentLoaded', async () => {
    const canvas = document.getElementById('particleCanvas');
    if (canvas) {
        particleBg = new ParticleBackground(canvas);
    }

    // Cache frequently-accessed DOM elements to avoid repeated getElementById calls
    _logArea    = document.getElementById('logArea');
    _logCount   = document.getElementById('logCount');
    _spinner    = document.getElementById('loadingSpinner');
    _overlay    = document.getElementById('loadingOverlay');
    _statConfig = document.getElementById('configChanges');
    _statFixes  = document.getElementById('fixesApplied');
    _statSpoof  = document.getElementById('spoofCount');
    _navItems   = Array.from(document.querySelectorAll('.nav-item'));
    _statusText = document.querySelector('.status-text');
    _statusDot  = document.querySelector('.status-dot');

    setLoading(true);
    MOD_PATH = await findModulePath();
    
    if (!MOD_PATH) {
        UIManager.showBanner("⚠️ Module not found! (ID: " + MOD_ID + ")", 'error');
        setLoading(false);
        return;
    }

    // ── AUTHOR LOCK CHECK ────────────────────────────────────────────────────
    // Must run before any other init. If the developer credit is missing from
    // module.prop, show the lock screen and abort.
    const authorOk = await checkModuleAuthor(MOD_PATH);
    if (!authorOk) {
        showAuthorLockScreen();
        setLoading(false);
        return;
    }
    // ────────────────────────────────────────────────────────────────────────
    
    MOD_WEB_LANG = `${MOD_PATH}/webroot/Languages`;
    MOD_DOCS = `${MOD_PATH}/Documentation`;

    // Navigation — also trigger scanGpuModels when Utils tab opens
    document.querySelectorAll('.nav-item').forEach(btn => {
        btn.addEventListener('click', () => {
            const target = btn.dataset.target || btn.dataset.tab;
            if (target) {
                switchTab(target);
                // Lazy-load GPU models when Utils tab is first opened
                const tabName = target.replace('tab-', '');
                if ((tabName === 'utils' || target === 'tab-utils') && !scanGpuModels._loaded) {
                    scanGpuModels._loaded = true;
                    scanGpuModels();
                }
            }
        });
    });

    // Helper function for binding events
    const bind = (id, fn) => {
        const el = document.getElementById(id);
        if (el) el.addEventListener('click', fn);
    };

    // Bind all buttons
    bind('btnSave', saveConfig);

    // ── TOGGLE ON-STATE ROW HIGHLIGHT ─────────────────────────────
    // When a toggle flips, mark the parent .setting-item with .is-on
    function syncSettingRowState(checkbox) {
        const settingItem = checkbox.closest('.setting-item');
        if (settingItem) {
            const wasOff = !settingItem.classList.contains('is-on');
            settingItem.classList.toggle('is-on', checkbox.checked);
            if (checkbox.checked && wasOff) {
                settingItem.classList.add('just-activated');
                setTimeout(() => settingItem.classList.remove('just-activated'), 600);
            }
        }
    }
    document.querySelectorAll('.setting-item input[type="checkbox"]').forEach(cb => {
        syncSettingRowState(cb);
        cb.addEventListener('change', () => syncSettingRowState(cb));
    });
    // Re-sync after config loads
    const _origLoadConfig = loadConfig;
    // (sync triggered in loadConfig via setToggle calls — covered by change events)
    bind('btnCustomDriverChanges', openCustomDriverModal);
    bind('closeCustomDriver', closeCustomDriverModal);

    const customDriverOverlay = document.getElementById('customDriverOverlay');
    if (customDriverOverlay) customDriverOverlay.addEventListener('click', closeCustomDriverModal);

    bind('btnApplySpoof', applyGpuSpoof);
    bind('btnRestoreOriginal', restoreOriginalGSL);
    bind('btnFixCamera', () => runFix("libCB.so libgpudataproducer.so libkcl.so libkernelmanager.so libllvm-qcom.so libOpenCL.so libOpenCL_adreno.so", "Camera Fix", "fixCameraWarning"));
    bind('btnFixRecorder', () => runFix("libC2D2.so libc2d30_bltlib.so libc2dcolorconvert.so", "Screen Recorder Fix", "fixRecorderWarning"));
    bind('btnFixNight', () => runFix("libsnapdragon_color_manager.so", "Night Mode Fix", "fixNightWarning"));
    bind('btnClearLogs', async () => {
        const confirmed = await ConfirmDialog.show(
            'Clear System Logs',
            'This will clear all system logs including booted, bootloop folders and /data/local/tmp. Continue?',
            '🗑️'
        );
        
        if (!confirmed) return;
        
        setLoading(true);
        logToTerminal('Clearing system logs...', 'info');

        try {
            // Clear UI logs
            if (_logArea) _logArea.innerHTML = '';
            terminalCache.entries = [];
            
            // Clear actual system log files and folders
            await exec(`rm -rf "${SD_ROOT}/Booted"/* 2>/dev/null`);
            await exec(`rm -rf "${SD_ROOT}/Bootloop"/* 2>/dev/null`);
            await exec(`rm -rf "${SD_ROOT}/Install"/* 2>/dev/null`);
            await exec(`rm -rf /data/local/tmp/* 2>/dev/null`);
            
            showToast(currentTranslations.clearLogs || "Logs Cleared");
            logToTerminal('✓ System logs cleared successfully', 'success');
        } catch (e) {
            logToTerminal('clearLogs error: ' + (e && e.message ? e.message : String(e)), 'error');
            showToast('❌ Failed to clear logs');
        } finally {
            setLoading(false);
        }
    });
    bind('btnCopyLogs', () => {
        if (_logArea) {
            navigator.clipboard.writeText(_logArea.innerText);
            showToast(currentTranslations.copyLogs || "Copied");
        }
    });
    bind('btnEditQGL', openQGLEditor);
    bind('btnSaveQGL', saveQGL);
    bind('closeQGL', () => document.getElementById('qglModal').style.display = 'none');
    bind('btnFormatQGL', () => {
    const el = document.getElementById('qglEditor');
    if (!el) return;
    // Clear editor contents (user must press Save to persist)
    el.value = '';
    if (typeof updateQGLLineCount === 'function') updateQGLLineCount();
    showToast('QGL editor cleared');
    logToTerminal('QGL editor cleared by Format', 'info');
    });
    bind('btnResetQGL', async () => {
    // Confirm with the user before destructive action
    const confirmed = await ConfirmDialog.show(
        'Reset QGL Config',
        'This will restore the original module QGL from default.txt.bak. Continue?',
        '♻️'
    );
    if (!confirmed) return;

    setLoading(true);

    const defaultBak = `${SD_ROOT}/default.txt.bak`;
    const userSave   = `${SD_ROOT}/qgl_config.txt`;
    const moduleFile = `${MOD_PATH}/qgl_config.txt`;

    try {
        // Ensure default backup exists
        const bakCheck = await exec(`[ -f "${defaultBak}" ] && echo "exists" || echo "missing"`);
        const bakExists = bakCheck && bakCheck.stdout && bakCheck.stdout.includes('exists');

        if (!bakExists) {
            showToast('⚠️ No default backup found. Reset aborted.');
            logToTerminal('Reset aborted: default.txt.bak missing', 'error');
            setLoading(false);
            return;
        }

        // Copy default backup into module and into the Adreno user file
        await exec(`cp "${defaultBak}" "${moduleFile}" 2>/dev/null || printf '%s' '' > "${moduleFile}"`);
        await exec(`cp "${defaultBak}" "${userSave}" 2>/dev/null || printf '%s' '' > "${userSave}"`);

        logToTerminal('Reset applied from default.txt.bak', 'success');
        showToast('✅ QGL reset to default (from default.txt.bak)');

        // Refresh the editor view to reflect restored config
        if (typeof openQGLEditor === 'function') await openQGLEditor();
    } catch (err) {
        const msg = err && err.message ? err.message : String(err);
        logToTerminal('Reset error: ' + msg, 'error');
        showToast(currentTranslations?.msgQGLFail || '❌ Failed to reset QGL Config');
    } finally {
        setLoading(false);
    }
    });
    bind('btnTopGuide', openDocs);
    
    // ── THEME PICKER ──────────────────────────────────────────────
    bind('btnThemePicker', openThemePicker);
    
    const themeOverlay = document.getElementById('themeOverlay');
    if (themeOverlay) themeOverlay.addEventListener('click', closeThemePicker);
    
    document.querySelectorAll('.theme-swatch').forEach(btn => {
        btn.addEventListener('click', () => {
            const theme = btn.dataset.theme;
            if (theme) applyAndSaveTheme(theme);
        });
    });

    // ── COLOR MODE TOGGLE ─────────────────────────────────────────
    initColorModeToggle();
    initQualityMode();
    bind('btnTransDocs', performDocsTranslation);
    bind('closeDocs', () => document.getElementById('docModal').style.display = 'none');
    bind('btnClearGPUCache', clearGPUCaches);
    bind('btnTrimStorage', trimStorage);
    bind('btnClearCustomLang', async () => {
        await exec(`rm "${SD_LANG}/custom.json" 2>/dev/null`);
        showToast(currentTranslations.clearCustomLang || "Custom language cleared");
    });
    bind('btnResetConfig', async () => {
        const confirmed = await ConfirmDialog.show(
            currentTranslations.resetDefaults || 'Reset Configuration', 
            'Reset all settings to defaults?', 
            '♻️'
        );
        if (confirmed) {
            setLoading(true);
            try {
                const defaults = `PLT=n\nQGL=n\nARM64_OPT=n\nVERBOSE=n\nRENDER_MODE=normal\nTHEME=purple`;
                const escapedDefaults = defaults.replace(/'/g, "'\\''");
                await exec(`echo '${escapedDefaults}' > "${SD_CONFIG}/adreno_config.txt"`);
                await exec(`echo '${escapedDefaults}' > "${MOD_PATH}/adreno_config.txt"`);
                await loadConfig();
                showToast('✅ Configuration reset to defaults');
            } catch (e) {
                logToTerminal('resetConfig error: ' + (e && e.message ? e.message : String(e)), 'error');
                showToast('❌ Failed to reset configuration');
            } finally {
                setLoading(false);
            }
        }
    });
    bind('btnApplyRenderNow', applyRenderNow);
    bind('btnExportLogs', () => {
        const logText = terminalCache.entries.map(e => `${e.timestamp} ${e.message}`).join('\n');
        const blob = new Blob([logText], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `adreno_logs_${new Date().toISOString().slice(0,10)}.txt`;
        a.click();
        URL.revokeObjectURL(url);
        showToast('✅ Logs exported');
    });

    // Modal overlay clicks
    const qglOverlay = document.getElementById('qglOverlay');
    if (qglOverlay) {
        qglOverlay.addEventListener('click', () => document.getElementById('qglModal').style.display = 'none');
    }
    
    const docOverlay = document.getElementById('docOverlay');
    if (docOverlay) {
        docOverlay.addEventListener('click', () => document.getElementById('docModal').style.display = 'none');
    }

    // Language selector
    const langSel = document.getElementById('LANG_SELECT');
    if (langSel) {
        langSel.addEventListener('change', handleLanguageChange);
        
        // Check if custom.json exists and enable custom option
        const customCheck = await exec(`[ -f "${SD_LANG}/custom.json" ] && echo "exists"`);
        if (customCheck.stdout && customCheck.stdout.includes('exists')) {
            const customOpt = document.getElementById('optCustom');
            if (customOpt) {
                customOpt.disabled = false;
                logToTerminal('✓ Custom language available', 'info');
            }
        }
        
        const saved = localStorage.getItem('adreno_lang') || 'en';
        langSel.value = saved;
        
        // Load appropriate language (NEVER trigger system detection on init to avoid blocking)
        if (saved === 'custom') {
            const loaded = await loadCustomLanguage();
            if (!loaded) {
                // Custom not found, fallback to English
                applyTranslations(DEFAULT_EN);
                currentLangCode = 'en';
                langSel.value = 'en';
            }
        } else if (saved === 'system') {
            // For system, just detect and apply without prompting
            let sysLangRes = await exec('getprop persist.sys.locale 2>/dev/null');
            if (!sysLangRes.stdout || !sysLangRes.stdout.trim()) {
                sysLangRes = await exec('getprop ro.product.locale 2>/dev/null');
            }
            const sysLangFull = sysLangRes.stdout.trim();
            const sysLang = sysLangFull.split('-')[0] || 'en';
            
            // Apply built-in languages if available
            if (sysLang === 'zh') {
                if (sysLangFull.includes('CN') || sysLangFull.includes('SG')) {
                    applyTranslations(BUILTIN_ZH_CN);
                    currentLangCode = 'zh-CN';
                } else {
                    applyTranslations(BUILTIN_ZH_TW);
                    currentLangCode = 'zh-TW';
                }
            } else if (sysLang === 'en') {
                applyTranslations(DEFAULT_EN);
                currentLangCode = 'en';
            } else {
                // Check if custom exists for this language
                const customLoaded = await loadCustomLanguage();
                if (customLoaded) {
                    currentLangCode = 'custom';
                } else {
                    // No custom, fallback to English (user can manually trigger translation)
                    applyTranslations(DEFAULT_EN);
                    currentLangCode = 'en';
                }
            }
        } else {
            const langMap = { 'zh-CN': BUILTIN_ZH_CN, 'zh-TW': BUILTIN_ZH_TW, 'en': DEFAULT_EN };
            if (langMap[saved]) {
                applyTranslations(langMap[saved]);
                currentLangCode = saved;
            }
        }
    }

    // QGL editor line count
    const qglEditor = document.getElementById('qglEditor');
    if (qglEditor) {
        qglEditor.addEventListener('input', updateQGLLineCount);
    }

    // Render mode description updater
    const renderModeSelect = document.getElementById('RENDER_MODE');
    const renderModeDesc = document.querySelector('.mode-desc-text');
    if (renderModeSelect && renderModeDesc) {
        const updateRenderModeDescription = async () => {
            const mode = renderModeSelect.value;
            const sdk = await getAndroidSdkVer();
            const descriptions = {
                'normal': currentTranslations.renderDesc || 'Default rendering backend — no debug props set',
                'skiavk': currentTranslations.renderDescSkiaVK || 'HWUI uses Skia+Vulkan — smoother UI on Adreno GPUs. renderengine.backend: skiavkthreaded if API ≥ 34 (or Force flag enabled), else skiaglthreaded.',
                'skiagl': currentTranslations.renderDescSkiaGL || 'HWUI uses Skia+OpenGL — better compatibility fallback. renderengine.backend=skiaglthreaded (threaded GL compositor, all versions).',
                'skiavk_all': currentTranslations.renderDescSkiaVKAll || 'SkiaVK + boot-time renderer activation subshell (boot+35s). Throttled force-stops all 3rd-party AND non-critical system apps (150ms gap, GMS/Meta/SystemUI excluded) so they cold-start with Vulkan. renderengine.backend: skiavkthreaded if API ≥ 34 (or Force flag enabled), else skiaglthreaded.',
            };
            renderModeDesc.textContent = descriptions[mode] || descriptions['normal'];
            updateForceThreadedRowVisibility();
        };

        renderModeSelect.addEventListener('change', updateRenderModeDescription);
        // Update on load
        updateRenderModeDescription();
    }

    // Load data
    await ensureDirectories();
    await loadSystemInfo();
    await loadConfig();
    await loadGameExclusionList();
    initGameExclSection();
    await loadStatistics();  // Load statistics after config
    
    // Animate performance bar
    setTimeout(() => {
        const perfBar = document.getElementById('performanceFill');
        if (perfBar) perfBar.style.width = '75%';
    }, 500);
    
    setLoading(false);
    UIManager.updateStatus(currentTranslations.statusReady || 'Ready', 'active');
    logToTerminal('🚀 Adreno Manager initialized successfully!', 'success');
});
