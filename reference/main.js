// ==========================================
// IMPORTS
// ==========================================

const { app, BrowserWindow, ipcMain } = require('electron');
const Store = require('electron-store');
const axios = require('axios');
const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const FormData = require('form-data');

// ==========================================
// APP CONFIGURATION
// ==========================================

app.commandLine.appendSwitch('disable-background-timer-throttling');
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');
app.commandLine.appendSwitch('wm-window-animations-disabled');

app.disableHardwareAcceleration();

// Single instance lock (prevent double instance)
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
    app.quit();
}

const store = new Store();

// API Client
const apiClient = axios.create({
    baseURL: 'https://feedback.pathosoft.info/api',
    timeout: 10000,
});

// ==========================================
// DATABASE SETUP
// ==========================================

const dbDir = path.join(app.getPath('userData'), 'FeedbackSystem');

if (!fs.existsSync(dbDir)) {
    fs.mkdirSync(dbDir, { recursive: true });
}

const dbPath = path.join(dbDir, 'feedback.db');

const db = new Database(dbPath, {
    fileMustExist: false,
    timeout: 5000
});

// Performance: WAL mode enable
db.pragma('journal_mode = WAL');

// ==========================================
// DATABASE TABLE + MIGRATION
// ==========================================

try {
    // Create table if it doesn't exist (including category_ids)
    db.prepare(`
        CREATE TABLE IF NOT EXISTS feedbacks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            org_id INTEGER,
            rating TEXT,
            comment TEXT,
            category_ids TEXT,
            voice_buffer BLOB,
            created_at TEXT,
            synced INTEGER DEFAULT 0
        )
    `).run();

    // Migration: Add missing columns
    const columns = db.prepare(`PRAGMA table_info(feedbacks)`).all();
    const columnNames = columns.map(column => column.name);

    if (!columnNames.includes('voice_buffer')) {
        db.prepare(`ALTER TABLE feedbacks ADD COLUMN voice_buffer BLOB`).run();
    }

    if (!columnNames.includes('category_ids')) {
        db.prepare(`ALTER TABLE feedbacks ADD COLUMN category_ids TEXT`).run();
    }

    if (!columnNames.includes('synced')) {
        db.prepare(`ALTER TABLE feedbacks ADD COLUMN synced INTEGER DEFAULT 0`).run();
    }

    if (!columnNames.includes('created_at')) {
        db.prepare(`ALTER TABLE feedbacks ADD COLUMN created_at TEXT`).run();
    }

    // Index
    db.prepare(`
        CREATE INDEX IF NOT EXISTS idx_org_date
        ON feedbacks (org_id, created_at)
    `).run();
} catch (error) {
}

// ==========================================
// WINDOW CREATION
// ==========================================

function createWindow() {
    const win = new BrowserWindow({
        fullscreen: true,
        frame: false,
        alwaysOnTop: true,
        autoHideMenuBar: true,
        backgroundColor: '#ffffff',
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false,
            webSecurity: false,
            backgroundThrottling: false
        }
    });

    win.on('blur', () => {
        win.focus();
    });

    win.loadFile(path.join(__dirname, 'src/index.html'));
}

// ==========================================
// IPC HANDLERS — AUTH & DATA
// ==========================================

ipcMain.handle('check-login-status', async () => {
    try {
        const orgId = store.get('org_id');
        return orgId ? { loggedIn: true, org_id: orgId } : { loggedIn: false };
    } catch (e) {
        return { loggedIn: false };
    }
});

ipcMain.handle('login-api', async (e, creds) => {
    try {
        const res = await apiClient.post('/login', creds);
        const orgId = res.data.org_id;
        store.set('org_id', orgId);
        return { success: true, org_id: orgId };
    } catch (error) {
        if (!error.response) {
            return { success: false, message: 'ইন্টারনেট কানেকশন নেই। অনুগ্রহ করে সংযোগটি চেক করুন।' };
        }
        return { success: false, message: 'ভুল ইমেইল বা পাসওয়ার্ড। আবার চেষ্টা করুন।' };
    }
});

ipcMain.handle('get-org-logo', async (e, org_id) => {
    try {
        const res = await apiClient.get(`/get-org-logo/${org_id}`);
        return res.data.logo;
    } catch (e) {
        return null;
    }
});

ipcMain.handle('get-marquee', async (e, org_id) => {
    try {
        const res = await apiClient.get(`/get-marquee-text/${org_id}`);
        return res.data;
    } catch (e) {
        return {
            heading: 'ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।',
            text: 'ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।'
        };
    }
});

// ==========================================
// IPC HANDLERS — CATEGORIES
// ==========================================

ipcMain.handle('get-org-categories', async (event, orgId) => {
    try {
        const response = await apiClient.post('/admin/get-categories', {
            organization_id: orgId
        });
        if (response.data && response.data.success) {
            return response.data.categories;
        }
        return [];
    } catch (error) {
        return [];
    }
});

// ==========================================
// IPC HANDLER — SAVE FEEDBACK (Offline & Online with Voice & Categories)
// ==========================================

ipcMain.handle('save-feedback-offline', async (e, data) => {
    try {
        const orgId = data.organization_id || data.org_id;
        const rating = data.rating;
        const comment = data.comment || '';
        const categoryIds = data.category_ids || [];
        let voiceBufferNode = null;

        let formData = new FormData();
        formData.append('organization_id', orgId);
        formData.append('rating', rating);
        formData.append('comment', comment);

        // Append Category IDs array for Laravel backend
        categoryIds.forEach(id => {
            formData.append('category_ids[]', id);
        });

        if (data.voiceBuffer) {
            voiceBufferNode = Buffer.from(data.voiceBuffer);
            if (voiceBufferNode.length > 10 * 1024 * 1024) {
                return { status: 'error', message: 'ভয়েস ফাইলের সাইজ ১০ এমবি এর বেশি হতে পারবে না।' };
            }
            formData.append('voice', voiceBufferNode, {
                filename: 'voice_note.webm',
                contentType: 'audio/webm',
            });
        }

        // Online submission attempt (Endpoint matched with backend /feedback/store)
        const response = await apiClient.post('/feedback/store', formData, {
            headers: { ...formData.getHeaders() }
        });

        // Successfully saved online — store locally with synced = 1
        db.prepare("INSERT INTO feedbacks (org_id, rating, comment, category_ids, voice_buffer, created_at, synced) VALUES (?,?,?,?,?,?,?)")
            .run(orgId, rating, comment, JSON.stringify(categoryIds), voiceBufferNode, new Date().toISOString(), 1);

        return response.data;

    } catch (error) {
        const orgId = data.organization_id || data.org_id;
        const rating = data.rating;
        const comment = data.comment || '';
        const categoryIds = data.category_ids || [];
        let voiceBufferNode = data.voiceBuffer ? Buffer.from(data.voiceBuffer) : null;

        if (error.response && error.response.data) {
            return error.response.data;
        }

        // No internet or failure — save to local SQLite with voice buffer & categories (synced = 0)
        db.prepare("INSERT INTO feedbacks (org_id, rating, comment, category_ids, voice_buffer, created_at, synced) VALUES (?,?,?,?,?,?,?)")
            .run(orgId, rating, comment, JSON.stringify(categoryIds), voiceBufferNode, new Date().toISOString(), 0);

        return { status: 'success', message: 'আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏' };
    }
});

// ==========================================
// BACKGROUND SYNC (Auto-sync unsynced feedbacks)
// ==========================================

async function syncOfflineFeedbacks() {
    try {
        const unsynced = db.prepare("SELECT * FROM feedbacks WHERE synced = 0 LIMIT 5").all();

        if (unsynced.length > 0) {
            for (let row of unsynced) {
                try {
                    let formData = new FormData();
                    formData.append('organization_id', row.org_id);
                    formData.append('rating', row.rating);
                    formData.append('comment', row.comment || '');

                    if (row.category_ids) {
                        const catIds = JSON.parse(row.category_ids);
                        catIds.forEach(id => {
                            formData.append('category_ids[]', id);
                        });
                    }

                    if (row.voice_buffer) {
                        formData.append('voice', Buffer.from(row.voice_buffer), {
                            filename: 'voice_note.webm',
                            contentType: 'audio/webm',
                        });
                    }

                    const response = await apiClient.post('/feedback/store', formData, {
                        headers: { ...formData.getHeaders() }
                    });

                    if (response.data && (response.data.status === 'success' || response.data.success)) {
                        db.prepare("UPDATE feedbacks SET synced = 1 WHERE id = ?").run(row.id);
                    }
                } catch (e) {
                    if (e.response && e.response.status === 422) {
                        db.prepare("UPDATE feedbacks SET synced = -1 WHERE id = ?").run(row.id);
                    } else {
                        break; // No internet — stop trying for now
                    }
                }
            }
        }
    } catch (err) {
        // Silent fail
    }
}

setInterval(syncOfflineFeedbacks, 30000);

// ==========================================
// APP READY
// ==========================================

app.whenReady().then(() => {
  app.setLoginItemSettings({
    openAtLogin: true,
    openAsHidden: false,
    path: app.getPath('exe'),
    args: []
  });
  createWindow();
});