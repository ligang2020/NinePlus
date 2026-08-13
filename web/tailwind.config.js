/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Display', 'SF Pro Text', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
      },
      boxShadow: {
        ios: '0 12px 32px rgba(15, 23, 42, 0.06), 0 2px 8px rgba(15, 23, 42, 0.03)',
        'ios-lg': '0 22px 60px rgba(15, 23, 42, 0.10), 0 3px 12px rgba(15, 23, 42, 0.05)',
      },
    },
  },
  plugins: [],
};
