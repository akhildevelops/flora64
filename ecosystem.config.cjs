// =============================================================================
// ecosystem.config.cjs — PM2 process config for flora64
//
// Used by the deploy pipeline to start / reload the production server.
// Can also be started manually:
//   pm2 start ecosystem.config.cjs
// =============================================================================

module.exports = {
  apps: [
    {
      name: 'flora64',
      script: './server.js',
      interpreter: 'node',
      env: {
        PORT: '3000',
        HOST: '0.0.0.0',
        NODE_ENV: 'production',
      },
      // Restart if memory exceeds 512 MB as a safety net
      max_memory_restart: '512M',
      // Log to PM2's logrotate-friendly logs
      error_file: 'logs/flora64-err.log',
      out_file: 'logs/flora64-out.log',
      merge_logs: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    },
  ],
};
