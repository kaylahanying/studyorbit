import { loadConfig } from './config.mjs';
import { createStudyServer } from './server.mjs';

let app;
try {
  const config = loadConfig();
  app = await createStudyServer(config);
  await new Promise((resolve, reject) => {
    app.server.once('error', reject);
    app.server.listen(config.port, config.host, resolve);
  });
  console.log(`StudyOrbit serving Flutter web at ${config.origin}; hosted AI ${config.configured ? 'configured' : 'unavailable'}.`);
  console.log(config.production ? 'Production requires a local HTTPS reverse proxy preserving Host.'
    : `Loopback development only; ${config.autoSession ? 'local sessions are automatic' : 'an invitation is required'}.`);
  let stopping = false;
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, async () => {
      if (stopping) return;
      stopping = true;
      try { await app.close(); } finally { process.exit(0); }
    });
  }
} catch {
  // Avoid printing exceptions that could embed a configured URL or secret.
  console.error('StudyOrbit startup refused. Check Node 26+, real build/web assets, loopback bind/public origin, writable SQLite path, provider configuration, and production session secret/invitation requirements.');
  if (app) await app.close().catch(() => {});
  process.exitCode = 1;
}
