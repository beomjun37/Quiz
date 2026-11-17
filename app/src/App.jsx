import { useEffect, useState } from 'react'
import Phone from './views/Phone'
import Screen from './views/Screen'
import Admin from './views/Admin'

// 해시 라우터 — GitHub Pages 에서 새로고침해도 404 가 안 난다.
//   #/        참가자 폰      #/screen  TV·빔프로젝터      #/admin  진행자
export default function App() {
  const [route, setRoute] = useState(location.hash.slice(1) || '/')
  useEffect(() => {
    const f = () => setRoute(location.hash.slice(1) || '/')
    addEventListener('hashchange', f); return () => removeEventListener('hashchange', f)
  }, [])
  if (route.startsWith('/screen')) return <Screen />
  if (route.startsWith('/admin')) return <Admin />
  return <Phone />
}
