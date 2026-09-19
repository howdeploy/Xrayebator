import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import i18n from './i18n'
import './styles/global.css'
import './styles/tailwind.css'

document.documentElement.classList.add('dark')
document.documentElement.setAttribute('data-theme', 'dark')
document.title = i18n.t('app.title')

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
