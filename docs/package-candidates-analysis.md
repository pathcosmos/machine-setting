# 추가하지 않은 라이브러리 후보 재분석

다른 프로젝트 venv에서 쓰이지만 현재 `packages/requirements-*.txt`에 넣지 않은 패키지들을, **추가하면 좋은 것** vs **선택/비추천**으로 재분석한 문서입니다.

**범위: Python 라이브러리만** — pip 설치 후 코드에서 `import`하여 사용하는 패키지만 대상으로 함. CLI 전용 도구·시스템 유틸은 제외.

---

## 1. 추가하면 좋은 후보 (추천)

| 패키지 | 사용처 | 용도 | 의존성 | 추천 이유 |
|--------|--------|------|--------|-----------|
| **ollama** | rag_llm_chaining | 로컬 LLM(Ollama) 클라이언트 | 가벼움 | 공식 패키지, 로컬/프라이빗 LLM 활용이 AI env와 잘 맞음. LangChain 등과 함께 쓰는 경우 많음. |
| **langchain-ollama** | rag_llm_chaining | LangChain ↔ Ollama 연동 | 가벼움 | 이미 LangChain을 쓰는 환경에서 로컬 LLM 파이프라인 구성 시 거의 필수. |
| **rank-bm25** | rag_llm_chaining | BM25 키워드 검색 | 가벼움 | RAG에서 hybrid search(벡터+키워드) 표준. LangChain BM25Retriever와 연동. 데이터/검색 그룹과 잘 맞음. |
| **ultralytics** | dkrns-ocr-cropper | YOLO 객체탐지/세그멘테이션 | 보통(torch 등) | 이미 torch가 있으므로 추가 부담 적음. 비전/OCR 파이프라인에서 자주 쓰임. |
| **asyncio-mqtt** | realtime_app/backend | 비동기 MQTT 클라이언트 | 가벼움 | 이미 paho-mqtt가 있음. 비동기 스택(anyio, asyncio)과 함께 쓸 때 적합. IoT/실시간 백엔드와 맞음. |

**정리:**  
- **ollama + langchain-ollama + rank-bm25** → 로컬 LLM + RAG 용도로 추가 시 이득이 큼.  
- **ultralytics** → 비전/객체탐지 쓰는 프로젝트가 있으면 data 또는 별도 그룹에 넣기 좋음.  
- **asyncio-mqtt** → MQTT 비동기 필요 시 web 또는 core 유틸 쪽에 추가 검토.

---

## 2. 선택적으로 추가할 만한 후보

| 패키지 | 사용처 | 용도 | 의존성 | 비고 |
|--------|--------|------|--------|------|
| **konlpy** (+ jpype1) | rag_llm_chaining | 한국어 형태소 분석 | 보통, **Java 필요** | 한국어 NLP 전용. Java 설치·JAVA_HOME 필요하므로 기본 그룹보다는 필요 시 설치하는 편이 나음. |
| **opencv-contrib-python** | dkrns-ocr-labeler, dkrns-ocr-cropper | OpenCV 추가 모듈 | 무거움 | opencv-python 대체용. 특수 모듈 필요할 때만 선택 설치 권장. |
| **onnx** | app_ui | ONNX 모델 포맷 읽기/쓰기 | 보통 | onnxruntime은 이미 있음. 모델 변환·편집이 필요하면 추가. |
| **black**, **isort** | mithral_qlora | 코드 포매터/임포트 정렬 | 가벼움 | 개발 도구. core에 넣으면 모든 env에 설치되므로, dev 전용 requirements나 선택 그룹이 있으면 거기 넣는 게 나음. |
| **pycryptodome** | dkrns-ocr-labeler, dkrns-ocr-cropper | 암호화 | 가벼움 | cryptography가 이미 있으면 대부분 커버. AES 등 저수준 제어 필요 시만 추가. |
| **colorlog** | dkrns-ocr-labeler, dkrns-ocr-cropper | 컬러 로깅 | 가벼움 | coloredlogs를 이미 넣었다면 역할 중복. 한 가지만 유지해도 됨. |

---

## 3. 추가 비추천 또는 당분간 보류

| 패키지 | 사용처 | 이유 |
|--------|--------|------|
| **paddleocr**, **paddlepaddle**, **paddlex** | dkrns-ocr-labeler, dkrns-ocr-cropper | 용량·의존성 매우 큼. easyocr 등 이미 있어 OCR은 커버 가능. Paddle 전용 프로젝트만 별도 venv 권장. |
| **modelscope** | dkrns-ocr-labeler, dkrns-ocr-cropper | Alibaba ModelScope 전용. 범용 AI env에는 필요 시에만 설치. |
| **aistudio-sdk**, **bce-python-sdk** | dkrns-ocr-labeler | 특정 클라우드/플랫폼 전용. 범용 requirements에는 넣지 않는 편이 좋음. |
| **surya-ocr**, **python-doctr**, **keras-ocr** | dkrns-ocr-labeler | OCR 전용. easyocr/pytesseract로 충분한 경우가 많고, 필요 시 해당 프로젝트 venv에만 설치. |
| **formulaic** | dhsteel-iba-data-profile | R 스타일 포뮬러. 통계/데이터 특화 프로젝트용. 범용 data 그룹에는 우선순위 낮음. |
| **lifelines** | dhsteel-iba-data-profile | 생존분석 전용. 필요 프로젝트 venv에만 설치 권장. |
| **pypika** | rag_llm_chaining, dhsteel 등 | SQL 빌더. 이미 SQLAlchemy 등이 있어서, 쿼리 빌더가 꼭 필요할 때만 선택. |

**제외 (Python 라이브러리 아님):** `git-filter-repo` — Git 히스토리 재작성용 CLI 도구. pip으로 설치되지만 코드에서 import하여 쓰는 라이브러리가 아니므로 본 목록에서 제외.

---

## 4. 요약 권장사항

1. **바로 넣어도 좋은 것 (추가 추천)**  
   - **ollama**, **langchain-ollama**, **rank-bm25** → 로컬 LLM·RAG용으로 core 또는 data 그룹에 추가.  
   - **ultralytics** → 비전 쓰는 경우 data(또는 gpu) 그룹에 추가.  
   - **asyncio-mqtt** → MQTT 비동기 필요 시 web/core 유틸에 추가.

2. **선택 추가**  
   - 한국어 NLP: **konlpy** (+ jpype1)는 필요 시에만 설치(Java 의존성 고려).  
   - 개발 도구: **black**, **isort**는 dev 전용 requirements가 있으면 그쪽에.  
   - **opencv-contrib-python**, **onnx**는 특수 요구 있을 때만.

3. **넣지 않는 쪽 권장**  
   - Paddle 계열, 플랫폼 전용 SDK, OCR 전용 라이브러리, 생존분석·포뮬러 등 도메인 특화 패키지는 해당 프로젝트 venv에서만 설치.

이 문서는 `packages/requirements-*.txt` 수정 시 참고용으로 두고, 위 추천 순서대로 반영하면 됩니다.
