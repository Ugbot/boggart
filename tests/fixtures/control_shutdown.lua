rawset(_G,'listener_at_shutdown',assert(serve.listen{socket=assert(os.getenv('BOGGART_TEST_SOCKET')),
  handler=function()return 200,'{}'end}))
print('retained control listener reaches application teardown')
