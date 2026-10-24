const path = require('path');
const CopyPlugin = require('copy-webpack-plugin');
const { DefinePlugin } = require('webpack');
const { endpointBundle, hostPermissions } = require('./config/endpoints.cjs');

module.exports = (env, argv) => {
  const isProduction = argv.mode === 'production';
  const endpoints = endpointBundle(process.env);

  return {
    entry: {
      background: './src/background.ts',
      content: './src/content.ts',
      'popup/popup': './src/popup/popup.ts',
    },
    output: {
      path: path.resolve(__dirname, 'dist'),
      filename: '[name].js',
      clean: true,
    },
    devtool: isProduction ? false : 'source-map',
    module: {
      rules: [
        {
          test: /\.ts$/,
          use: 'ts-loader',
          exclude: /node_modules/,
        },
      ],
    },
    resolve: {
      extensions: ['.ts', '.js'],
    },
    plugins: [
      new DefinePlugin({ __OMP_ENDPOINTS__: JSON.stringify(endpoints) }),
      new CopyPlugin({
        patterns: [
          { from: 'manifest.json', to: 'manifest.json', transform(content) {
            const manifest = JSON.parse(content.toString());
            manifest.host_permissions = [...new Set([...manifest.host_permissions, ...hostPermissions(endpoints)])];
            return JSON.stringify(manifest, null, 2);
          } },
          { from: 'src/popup/popup.html', to: 'popup/popup.html' },
          { from: 'src/popup/popup.css', to: 'popup/popup.css' },
          { from: 'assets', to: 'assets', noErrorOnMissing: true },
          { from: 'icons', to: 'icons', noErrorOnMissing: true },
        ],
      }),
    ],
    optimization: {
      minimize: isProduction,
    },
  };
};
