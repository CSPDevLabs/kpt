FROM python:3.11-slim

# -------- Proxy arguments (Optional) --------
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# -------- Set proxy environment variables --------
ENV http_proxy=$HTTP_PROXY
ENV https_proxy=$HTTPS_PROXY
ENV no_proxy=$NO_PROXY

ENV HTTP_PROXY=$HTTP_PROXY
ENV HTTPS_PROXY=$HTTPS_PROXY
ENV NO_PROXY=$NO_PROXY

# -------- Install Flask --------
RUN pip install --no-cache-dir flask

# -------- Create working directory --------
WORKDIR /app

# -------- Copy application specific files --------
COPY app.py /app/
COPY templates/ /app/templates
#COPY static/ /app/static

# -------- Expose port --------
EXPOSE 5000

# -------- Start Flask app --------
CMD ["python", "app.py"]