FROM python:3.14-slim

WORKDIR /usr/src/app

# Cache pip downloads across builds to skip the ~3 GB torch fetch.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --extra-index-url https://download.pytorch.org/whl/cu126 \
        torch numpy

COPY <<'PY' main.py
import torch
print(f"CUDA available: {torch.cuda.is_available()}")
print(f"GPU 0: {torch.cuda.get_device_name(0)}")
PY

CMD ["python", "main.py"]
