FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt /app/requirements.txt
# Use Tencent Cloud PyPI mirror for GFW-restricted servers
RUN pip install --no-cache-dir \
    -i https://mirrors.aliyun.com/pypi/simple/ \
    --trusted-host mirrors.aliyun.com \
    -r /app/requirements.txt
COPY app.py /app/app.py
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
