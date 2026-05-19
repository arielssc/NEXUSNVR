const http = require('http');
const fs = require('fs');
const { spawn } = require('child_process');

const YAML_PATH = '/data/go2rtc.yaml';
const CONFIG_PATH = '/app/nvr_config.json';
const CAMERA_NAME_RE = /^[A-Za-z0-9_-]{1,48}$/;
const SAFE_TEXT_RE = /^[A-Za-z0-9_./:%+@?=&,\-]+$/;
const NAME_FORMAT_RE = /^%[HIMSpHMSYymd_\-%.]+$/;

function json(res, statusCode, payload) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(payload));
}

function redact(value) {
    return String(value || '').replace(/([a-z]+:\/\/)([^:@/\s]+):([^@/\s]+)@/gi, '$1***:***@');
}

function publicError(error) {
    return redact(error && error.message ? error.message : error);
}

function runCommand(command, args, options = {}) {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
        let stdout = '';
        let stderr = '';

        child.stdout.on('data', chunk => { stdout += chunk.toString(); });
        child.stderr.on('data', chunk => { stderr += chunk.toString(); });
        child.on('error', reject);
        child.on('close', code => {
            if (code === 0) {
                resolve({ stdout, stderr });
                return;
            }

            const detail = stderr.trim() || stdout.trim() || `codigo ${code}`;
            reject(new Error(`${command} ${args.join(' ')} falhou: ${detail}`));
        });
    });
}

function runDocker(args) {
    return runCommand('docker', args);
}

function assertCameraName(name, label = 'nome da camera') {
    if (typeof name !== 'string' || !CAMERA_NAME_RE.test(name)) {
        throw new Error(`${label} invalido. Use 1 a 48 caracteres: letras, numeros, _ ou -.`);
    }
}

function assertSafeText(value, label) {
    if (typeof value !== 'string' || value.length === 0 || value.length > 255 || !SAFE_TEXT_RE.test(value)) {
        throw new Error(`${label} invalido.`);
    }
}

function oneOf(value, allowed, fallback) {
    const finalValue = value === undefined || value === null || value === '' ? fallback : String(value);
    if (!allowed.includes(finalValue)) {
        throw new Error(`Valor invalido: ${finalValue}`);
    }
    return finalValue;
}

function numberString(value, fallback, min, max, label) {
    const raw = value === undefined || value === null || value === '' ? fallback : String(value);
    if (!/^[0-9]+$/.test(raw)) {
        throw new Error(`${label} deve ser numerico.`);
    }

    const n = Number(raw);
    if (n < min || n > max) {
        throw new Error(`${label} fora do limite permitido.`);
    }
    return raw;
}

function assertUrl(value, label) {
    if (typeof value !== 'string' || value.trim() === '' || value.includes('[IP]')) {
        throw new Error(`${label} vazio ou nao configurado.`);
    }

    let parsed;
    try {
        parsed = new URL(value);
    } catch {
        throw new Error(`${label} invalido.`);
    }

    const allowed = ['rtsp:', 'rtsps:', 'http:', 'https:', 'rtmp:'];
    if (!allowed.includes(parsed.protocol)) {
        throw new Error(`${label} com protocolo nao permitido.`);
    }
}

function loadDb() {
    if (!fs.existsSync(CONFIG_PATH)) return {};
    try {
        return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    } catch {
        return {};
    }
}

function saveDb(db) {
    const tmp = `${CONFIG_PATH}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
    fs.renameSync(tmp, CONFIG_PATH);
}

function buildGo2rtcYaml(db) {
    let yamlContent = 'streams:\n';

    for (let i = 1; i <= 4; i++) {
        const c = db[i];
        if (c && c.active && c.name && c.url && !c.url.includes('[IP]')) {
            assertCameraName(c.name);
            assertUrl(c.url, `URL da camera ${c.name}`);
            yamlContent += `  ${c.name}: ${c.url}\n`;
        }
    }

    const webrtcCandidates = (process.env.WEBRTC_CANDIDATES || '')
        .split(',')
        .map(v => v.trim())
        .filter(Boolean);

    yamlContent += '\n';
    yamlContent += '# Nexus NVR - WebRTC pela mesma porta publica do painel\n';
    yamlContent += '# TCP fica no Nginx; UDP da mesma porta vai para o Go2RTC.\n';
    yamlContent += 'webrtc:\n';
    yamlContent += '  listen: ":8555"\n';

    if (webrtcCandidates.length > 0) {
        yamlContent += '  candidates:\n';
        for (const candidate of webrtcCandidates) {
            assertSafeText(candidate, 'candidate WebRTC');
            yamlContent += `    - ${candidate}\n`;
        }
    }

    fs.writeFileSync(YAML_PATH, yamlContent);
}

function buildRecorderArgs(cam, recUrlFinal) {
    const proto = oneOf(cam.proto, ['tcp', 'udp'], 'udp');
    const restartPolicy = oneOf(cam.restart, ['no', 'always', 'unless-stopped', 'on-failure'], 'unless-stopped');
    const vcodec = oneOf(cam.vcodec, ['copy', 'libx264', 'h264'], 'copy');
    const acodec = oneOf(cam.acodec, ['copy', 'aac', 'none'], 'aac');
    const format = oneOf(cam.format, ['mkv', 'mp4', 'ts'], 'mkv');
    const tz = cam.tz || process.env.TZ || 'America/Sao_Paulo';
    const delay = numberString(cam.delay, '5000000', 0, 60000000, 'max_delay');
    const timeout = numberString(cam.timeout, '5000000', 1000000, 120000000, 'timeout');
    const analyzeDuration = numberString(cam.analyzeduration, '10000000', 0, 120000000, 'analyzeduration');
    const probeSize = numberString(cam.probe, '10000000', 32768, 120000000, 'probesize');
    const segTimeSecs = Number(numberString(cam.segtime, '10', 1, 1440, 'tempo do segmento')) * 60;
    const nameFormat = cam.nameformat || '%H-%M-%S';
    const ffFlags = cam.genpts !== false ? '+genpts+discardcorrupt' : '+discardcorrupt';

    assertSafeText(tz, 'fuso horario');
    if (!NAME_FORMAT_RE.test(nameFormat)) {
        throw new Error('formato do nome do arquivo invalido.');
    }

    const args = [
        'run', '-d',
        `--name=gravador_${cam.name}`,
        '--restart', restartPolicy,
        '-e', `TZ=${tz}`,
        '-v', '/usr/share/zoneinfo:/usr/share/zoneinfo:ro',
        '-v', '/etc/localtime:/etc/localtime:ro',
        '-v', '/etc/timezone:/etc/timezone:ro',
        '-v', '/home/nexus/gravacoes:/gravacoes',
        'jrottenberg/ffmpeg:latest',
    ];

    if (recUrlFinal.toLowerCase().startsWith('rtsp://') || recUrlFinal.toLowerCase().startsWith('rtsps://')) {
        args.push('-rtsp_transport', proto);
    }

    args.push(
        '-fflags', ffFlags,
        '-err_detect', 'ignore_err',
        '-max_delay', delay,
        '-timeout', timeout,
        '-analyzeduration', analyzeDuration,
        '-probesize', probeSize,
        '-i', recUrlFinal,
        '-c:v', vcodec
    );

    if (acodec === 'none') {
        args.push('-an');
    } else {
        args.push('-c:a', acodec);
    }

    args.push(
        '-f', 'segment',
        '-segment_time', String(segTimeSecs),
        '-segment_format', format,
        '-reset_timestamps', '1',
        '-strftime', '1',
        `/gravacoes/${cam.name}/%d-%m-%Y/${nameFormat}.${format}`
    );

    return args;
}

async function removeRecorder(name) {
    if (!name) return;
    assertCameraName(name, 'nome antigo da camera');
    try {
        await runDocker(['rm', '-f', `gravador_${name}`]);
    } catch (error) {
        if (!String(error.message || '').includes('No such container')) {
            throw error;
        }
    }
}

async function startRecorder(cam) {
    const recUrlFinal = cam.recurl && cam.recurl.trim() !== '' ? cam.recurl : cam.url;
    assertUrl(recUrlFinal, 'URL de gravacao');

    const dateObj = new Date();
    const dia = String(dateObj.getDate()).padStart(2, '0');
    const mes = String(dateObj.getMonth() + 1).padStart(2, '0');
    const ano = dateObj.getFullYear();
    const folderHoje = `/gravacoes/${cam.name}/${dia}-${mes}-${ano}`;

    await runDocker(['run', '--rm', '-v', '/home/nexus/gravacoes:/gravacoes', 'alpine', 'mkdir', '-p', folderHoje]);
    await runDocker(buildRecorderArgs(cam, recUrlFinal));
}

let db = loadDb();

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        return res.end();
    }

    if (req.method === 'GET' && req.url === '/maestro/config') {
        return json(res, 200, db);
    }

    if (req.method === 'POST' && req.url === '/maestro/save-cam') {
        let body = '';
        req.on('data', chunk => {
            body += chunk.toString();
            if (body.length > 1024 * 128) {
                req.destroy(new Error('Payload muito grande.'));
            }
        });

        req.on('end', async () => {
            let previousDb = db;

            try {
                const payload = JSON.parse(body);
                const id = String(payload.id || '');
                const oldName = payload.oldName;
                const cam = payload.config || {};

                if (!/^[1-4]$/.test(id)) {
                    throw new Error('ID da camera invalido.');
                }

                if (cam.name) assertCameraName(cam.name);
                if (oldName) assertCameraName(oldName, 'nome antigo da camera');
                if (cam.active && cam.url) assertUrl(cam.url, 'URL da camera');

                previousDb = { ...db };
                db = { ...db, [id]: cam };
                saveDb(db);
                buildGo2rtcYaml(db);

                await runDocker(['restart', 'go2rtc']);
                await new Promise(resolve => setTimeout(resolve, 2000));

                if (oldName && cam.name && oldName !== cam.name) {
                    await removeRecorder(oldName);
                }

                if (cam.name) {
                    await removeRecorder(cam.name);
                }

                let recorder = 'not_started';
                if (cam.active && cam.rec_active && cam.name) {
                    await startRecorder(cam);
                    recorder = 'started';
                }

                return json(res, 200, {
                    status: 'ok',
                    id,
                    camera: cam.name || null,
                    recorder,
                    container: cam.name ? `gravador_${cam.name}` : null,
                });
            } catch (error) {
                db = previousDb;
                try {
                    saveDb(db);
                    buildGo2rtcYaml(db);
                } catch (rollbackError) {
                    console.error('Falha no rollback:', publicError(rollbackError));
                }

                console.error('Erro ao salvar camera:', publicError(error));
                return json(res, 500, { status: 'error', msg: publicError(error) });
            }
        });
        return;
    }

    res.writeHead(404);
    res.end();
});

server.listen(3000, () => {
    console.log('API Maestro rodando na porta 3000 com validação e comandos Docker seguros.');
});
