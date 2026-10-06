FROM alpine:3.24

WORKDIR /sang
LABEL maintainer="ssub"
COPY app.sh .
RUN chmod +x app.sh
RUN echo "Hello env"
CMD ["./app.sh"]
