FROM python:3.12-slim
RUN pip install --no-cache-dir pymysql aiomysql
COPY *.py /
ENTRYPOINT ["python", "-u", "/loadgen.py"]
