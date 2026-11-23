import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { writeFileSync, mkdirSync } from 'node:fs'

// 빌드할 때마다 버전(빌드 시각)을 앱 안과 dist/version.json 에 같이 넣는다.
// 열려 있는 화면이 주기적으로 version.json 을 확인해 새 배포를 알아차린다.
const BUILD = String(Date.now())
const versionFile = { name: 'version-file', closeBundle() { mkdirSync('dist', { recursive: true }); writeFileSync('dist/version.json', JSON.stringify({ build: BUILD })) } }

// GitHub Pages 하위 경로(레포 이름)와 같아야 한다. 레포 이름을 바꾸면 여기도 바꾼다.
export default defineConfig({ base: '/Quiz/', plugins: [react(), versionFile], define: { __BUILD__: JSON.stringify(BUILD) } })
