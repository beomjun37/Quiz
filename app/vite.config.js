import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// GitHub Pages 하위 경로(레포 이름)와 같아야 한다. 레포 이름을 바꾸면 여기도 바꾼다.
export default defineConfig({ base: '/Quiz/', plugins: [react()] })
