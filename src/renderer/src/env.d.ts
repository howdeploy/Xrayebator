declare module '*.module.css' {
  const classes: { readonly [key: string]: string }
  export default classes
}

declare module '*.css'

declare module '*.json' {
  const value: unknown
  export default value
}

/**
 * Минимум типов Vite-HMR: полный `vite/client` в проект не подключён, а i18n
 * обновляет строки при правке JSON именно через `import.meta.hot`.
 */
interface ImportMeta {
  readonly hot?: {
    accept: (
      deps: string[],
      callback: (modules: Array<{ default?: unknown } | undefined>) => void
    ) => void
  }
}

declare module '*.svg' {
  const src: string
  export default src
}

declare module '*.jpg' {
  const src: string
  export default src
}

declare module '*.png' {
  const src: string
  export default src
}
